package main

import (
	"context"
	"functions/handler/http"
	"functions/repository"
	"log"
	"os"

	"github.com/azure/azure-functions-golang-worker/sdk"
	"github.com/azure/azure-functions-golang-worker/worker"
)

// connStringSetting names the app setting holding the database connection
// string. The Functions host exposes app settings as environment variables:
// locally from Values in local.settings.json, in Azure from the function app's
// application settings. The string carries no secret, since the database uses
// Entra authentication: ActiveDirectoryDefault locally (your az login) and
// ActiveDirectoryManagedIdentity in Azure.
const connStringSetting = "CERTDB_CONNECTION_STRING"

func main() {
	connString := os.Getenv(connStringSetting)
	if connString == "" {
		log.Fatalf("%s is not set; add it to local.settings.json or the function app's settings", connStringSetting)
	}

	store, err := repository.New(context.Background(), connString)
	if err != nil {
		log.Fatalf("connecting to certdb: %v", err)
	}
	defer store.Close()

	app := sdk.FunctionApp()

	http.RegisterHandlers(app, store)

	worker.Start(app)
}
