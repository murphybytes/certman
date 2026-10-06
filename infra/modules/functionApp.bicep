// Go function app on the Flex Consumption plan (the only plan the native Go
// worker supports while in preview), with everything it needs:
// - a user-assigned managed identity used for storage, Application Insights
//   and Azure SQL, so no keys or passwords are stored anywhere
// - a storage account for the Functions host and deployment packages, with
//   shared key access disabled
// - Log Analytics and Application Insights, with local auth disabled
// - outbound vnet integration, so the app reaches Azure SQL through its
//   private endpoint

param location string
param functionAppName string
param planName string
param identityName string
param storageAccountName string
param logAnalyticsName string
param appInsightsName string

@description('Subnet delegated to Microsoft.App/environments for vnet integration.')
param functionsSubnetId string

param sqlServerFqdn string
param sqlDatabaseName string

@description('Maximum number of instances the app scales out to.')
@minValue(1)
@maxValue(1000)
param maximumInstanceCount int

@description('Memory per instance in MB.')
@allowed([
  512
  2048
  4096
])
param instanceMemoryMB int

param tags object

var deploymentContainerName = 'app-package'

// Built-in role definition IDs.
var roles = {
  storageBlobDataOwner: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  storageQueueDataContributor: '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
  storageTableDataContributor: '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
  monitoringMetricsPublisher: '3913510d-42f4-4e42-8a64-420c390055eb'
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: deploymentContainerName
}

// The Functions host uses blobs, queues and tables in its storage account.
resource storageRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for roleId in [
    roles.storageBlobDataOwner
    roles.storageQueueDataContributor
    roles.storageTableDataContributor
  ]: {
    name: guid(storage.id, identity.id, roleId)
    scope: storage
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
      principalId: identity.properties.principalId
      principalType: 'ServicePrincipal'
    }
  }
]

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    DisableLocalAuth: true
  }
}

resource appInsightsRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appInsights.id, identity.id, roles.monitoringMetricsPublisher)
  scope: appInsights
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.monitoringMetricsPublisher)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  tags: tags
  kind: 'functionapp'
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    virtualNetworkSubnetId: functionsSubnetId
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: identity.id
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: maximumInstanceCount
        instanceMemoryMB: instanceMemoryMB
      }
      runtime: {
        name: 'go'
        version: '1.0'
      }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      appSettings: [
        // Identity-based connection to the host's storage account.
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storage.name
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'AzureWebJobsStorage__clientId'
          value: identity.properties.clientId
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING'
          value: 'ClientId=${identity.properties.clientId};Authorization=AAD'
        }
        // Read by functions/main.go. Contains no secret: the app signs in to
        // Azure SQL as its managed identity ("user id" is the identity's client ID).
        {
          name: 'CERTDB_CONNECTION_STRING'
          value: 'sqlserver://${sqlServerFqdn}?database=${sqlDatabaseName}&fedauth=ActiveDirectoryManagedIdentity&user%20id=${identity.properties.clientId}'
        }
      ]
    }
  }
  dependsOn: [
    // The host needs storage and monitoring access before it starts.
    storageRoleAssignments
    appInsightsRoleAssignment
    deploymentContainer
  ]
}

output functionAppName string = functionApp.name
output functionAppHostName string = functionApp.properties.defaultHostName
output identityPrincipalId string = identity.properties.principalId
output identityClientId string = identity.properties.clientId
