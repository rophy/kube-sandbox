package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"

	"github.com/rophy/kube-sandbox/internal/status"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	cfg := status.LoadConfig()

	http.HandleFunc("/status", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
			return
		}

		ctx := r.Context()
		checker, err := status.NewChecker(ctx, cfg)
		if err != nil {
			log.Printf("Error creating checker: %v", err)
			http.Error(w, "Internal server error", http.StatusInternalServerError)
			return
		}

		st, err := checker.GetStatus(ctx)
		if err != nil {
			log.Printf("Error getting status: %v", err)
			http.Error(w, "Internal server error", http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(st)
	})

	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	log.Printf("Starting server on :%s", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
