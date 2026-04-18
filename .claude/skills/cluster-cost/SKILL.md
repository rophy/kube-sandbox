---
description: Estimate the AWS cost for a cluster lifecycle (creation to destruction)
---

# Cluster Cost Estimation

Estimate the cost of a kube-sandbox cluster run by measuring its lifetime and computing EC2 charges.

## Steps

1. **Determine the region** from `terraform/cluster/variables.tf` (the `aws_region` default).

2. **List cluster lifecycles** by querying CloudTrail for VPC create/delete events:
   ```bash
   AWS_PROFILE=kube-sandbox aws cloudtrail lookup-events \
     --lookup-attributes AttributeKey=EventName,AttributeValue=CreateVpc \
     --region <region> --start-time <start>T00:00:00Z --end-time <end>T00:00:00Z \
     --query 'Events[*].EventTime' --output text
   ```
   Do the same for `DeleteVpc`. Match pairs chronologically to get each cluster's duration.

3. **Ask the user which lifecycle** to estimate (if multiple exist), or use the most recent one.

4. **Check if the cluster is older than 24 hours.** If so, prefer actual cost data from AWS Cost Explorer over estimation:
   ```bash
   AWS_PROFILE=kube-sandbox aws ce get-cost-and-usage \
     --time-period Start=<vpc-create-date>,End=<vpc-delete-date+1> \
     --granularity DAILY --metrics UnblendedCost \
     --filter '{"Dimensions":{"Key":"REGION","Values":["<region>"]}}' \
     --group-by Type=DIMENSION,Key=SERVICE \
     --output json
   ```
   Cost Explorer data typically appears within 24 hours. If available, report actual costs instead of estimates.

5. **For recent clusters (< 24h), estimate from spec.** Read `terraform/cluster/terraform.tfvars` to get:
   - Worker node count and instance types (grouped by role)
   - Master instance type (from `variables.tf` auto-select logic if not explicit):
     - workers <= 5: t3.small
     - workers <= 20: t3.medium
     - workers > 20: t3.xlarge

6. **Look up on-demand pricing** for each instance type in the region. Use `aws pricing` API or known rates. Common rates (verify if stale):
   - c7i.4xlarge: ~$0.70/hr (ap-east-2), ~$0.82/hr (ap-southeast-1)
   - t3.xlarge: ~$0.17/hr
   - t3.medium: ~$0.04/hr
   - t3.small: ~$0.02/hr

7. **Calculate and present** a cost table:

   | Component | Count | $/hr each | Hours | Cost |
   |---|---|---|---|---|
   | <instance_type> (<role>) | N | $X.XX | H | $XX.XX |
   | ... | | | | |
   | **Total** | | | | **$XX.XX** |

   Duration = time between VPC creation and VPC deletion.
   Assume all nodes were running for the full duration (conservative estimate).

## Notes

- EC2 bills per-second with a 1-minute minimum.
- EBS costs are small relative to compute for short-lived clusters but can add up if volumes are orphaned. Check `EC2 - Other` in Cost Explorer for EBS charges.
- This estimate covers EC2 compute only, not data transfer or EBS.
