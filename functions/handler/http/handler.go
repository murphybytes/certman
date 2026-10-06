// Package http constains http handlers for Azure function  
package http

import (
	"functions/repository"
	"log"
	"net/http"

	"github.com/azure/azure-functions-golang-worker/sdk"
)

type Handler struct {
	db repository.Store
}

func RegisterHandlers(app *sdk.App, store repository.Store) {
	h := &Handler{db: store}
	app.HTTP(
		"hello", 
		h.HTTPTriggerHandler,
		sdk.WithMethods("GET"),
		sdk.WithAuth("anonymous"),
		)
}

func (h *Handler) HTTPTriggerHandler(w http.ResponseWriter, r *http.Request) {
	log.Printf("Processing HTTP Trigger for %s", r.URL.Path)
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("Hello from Go Worker!"))
}







