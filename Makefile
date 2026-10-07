# Usage: make <target> ENV=dev|prod [LOCATION=<azure-region>]

ENV ?= dev
LOCATION ?= centralus

ifeq ($(filter $(ENV),dev prod),)
$(error ENV must be 'dev' or 'prod', got '$(ENV)')
endif

INFRA_DIR := infra
INFRA_PARAMS := $(INFRA_DIR)/environments/$(ENV).bicepparam
DEPLOYMENT_NAME := certman-$(ENV)
# Must match the resource group name built in infra/main.bicep.
RESOURCE_GROUP := rg-certman-$(ENV)

DB_PROJECT := db/db.sqlproj
DB_DACPAC := db/bin/Release/db.dacpac
DB_PUBLISH_PROFILE := db/db.publish.xml
# Must match the users group name built in infra/main.bicep.
DB_USERS_GROUP := grp_certdb_users_$(ENV)

# Shell snippet that looks up the ENV deployment's outputs, setting $$1 to the
# SQL server FQDN and $$2 to the database name.
LOAD_DB_OUTPUTS = outputs=$$(az deployment sub show --name $(DEPLOYMENT_NAME) \
		--query '[properties.outputs.sqlServerFqdn.value, properties.outputs.sqlDatabaseName.value]' \
		-o tsv) || { echo "No '$(DEPLOYMENT_NAME)' deployment found; run 'make infra-deploy ENV=$(ENV)' first." >&2; exit 1; }; \
	set -- $$outputs

# sqlpackage arguments shared by db-script and db-deploy. Signs in with your az
# login session.
# - Users, role memberships and their permissions are managed by
#   db/Script.PostDeployment.sql, so they're excluded from the schema comparison;
#   otherwise the profile's Drop*NotInSource settings would drop them (including
#   the users group's CONNECT permission) on every publish.
# - ScriptDatabaseOptions=False keeps Azure SQL's database settings (snapshot
#   isolation, MAXDOP, Query Store) instead of resetting them to project defaults.
DB_SQLPACKAGE_ARGS = /SourceFile:$(DB_DACPAC) \
		/Profile:$(DB_PUBLISH_PROFILE) \
		/TargetConnectionString:"Server=tcp:$$1,1433;Database=$$2;Authentication=Active Directory Default;Encrypt=True;" \
		/p:ExcludeObjectTypes="Users;RoleMembership;Permissions" \
		/p:ScriptDatabaseOptions=False \
		/v:CertdbUsersGroup=$(DB_USERS_GROUP)

.PHONY: help infra-build infra-what-if infra-deploy infra-destroy test-db db-build db-script db-deploy app-publish

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'

infra-build: ## Compile and lint the Bicep files
	az bicep build --file $(INFRA_DIR)/main.bicep --stdout > /dev/null
	az bicep build-params --file $(INFRA_DIR)/environments/dev.bicepparam --stdout > /dev/null
	az bicep build-params --file $(INFRA_DIR)/environments/prod.bicepparam --stdout > /dev/null

infra-what-if: ## Preview changes to the ENV resources
	az deployment sub what-if \
		--name $(DEPLOYMENT_NAME) \
		--location $(LOCATION) \
		--parameters $(INFRA_PARAMS)

infra-deploy: ## Create or update the ENV resources
	az deployment sub create \
		--name $(DEPLOYMENT_NAME) \
		--location $(LOCATION) \
		--parameters $(INFRA_PARAMS)

infra-destroy: ## Delete the ENV resource group and everything in it (prompts first)
	az group delete --name $(RESOURCE_GROUP)
	-az deployment sub delete --name $(DEPLOYMENT_NAME)

# Builds the connection string from the ENV deployment's outputs and signs in
# with your az login session. -count=1 skips cached results, since the
# database can change between runs.
test-db: ## Run repository tests against the ENV database
	@$(LOAD_DB_OUTPUTS); \
	CERTDB_CONNECTION_STRING="sqlserver://$$1?database=$$2&fedauth=ActiveDirectoryDefault" \
		go test -C functions -count=1 -v ./repository/...

build-app: 
	go build -C functions -o bin/app 

# Looks up the function app name from the ENV deployment's outputs. Core Tools
# builds the Go binary and packages it; local.settings.json isn't published,
# since the app's settings come from infra/modules/functionApp.bicep.
# --go is required: Core Tools infers the language from local.settings.json,
# which is gitignored, so without the flag a fresh clone fails with
# "Can't determine project language from files".
app-publish: ## Build and deploy the function app code to ENV
	@app=$$(az deployment sub show --name $(DEPLOYMENT_NAME) \
		--query properties.outputs.functionAppName.value -o tsv) && [ -n "$$app" ] \
		|| { echo "No function app in the '$(DEPLOYMENT_NAME)' deployment; run 'make infra-deploy ENV=$(ENV)' first." >&2; exit 1; }; \
	cd functions && func azure functionapp publish "$$app" --go

db-build: ## Build the database project into a dacpac
	dotnet build $(DB_PROJECT) -c Release

db-script: db-build ## Write the SQL that db-deploy would run to db/bin/deploy-ENV.sql
	dotnet tool restore
	@$(LOAD_DB_OUTPUTS); \
	dotnet tool run sqlpackage /Action:Script $(DB_SQLPACKAGE_ARGS) \
		/OutputPath:db/bin/deploy-$(ENV).sql

db-deploy: db-build ## Publish the database schema and post-deployment script to ENV
	dotnet tool restore
	@$(LOAD_DB_OUTPUTS); \
	dotnet tool run sqlpackage /Action:Publish $(DB_SQLPACKAGE_ARGS)
