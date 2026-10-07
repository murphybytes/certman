// Entry point for certman infrastructure. Deployed at subscription scope so it
// can create the resource group; everything else lives inside that group,
// except the Entra groups, which are tenant-level objects.
targetScope = 'subscription'

extension microsoftGraphV1

import { firewallRule } from 'modules/sql.bicep'

@description('Deployment environment.')
@allowed([
  'dev'
  'prod'
])
param environmentName string

@description('Azure region for all resources. Defaults to the deployment location.')
param location string = deployment().location

@description('Short project name used in resource names.')
param projectName string = 'certman'

@description('Address space for the virtual network.')
param vnetAddressPrefix string

@description('Address prefix for the private endpoints subnet.')
param privateEndpointsSubnetPrefix string

@description('Address prefix for the function app\'s vnet integration subnet.')
param functionsSubnetPrefix string

@description('Whether the SQL server accepts traffic from public networks (firewall rules still apply).')
@allowed([
  'Enabled'
  'Disabled'
])
param sqlPublicNetworkAccess string

@description('IPv4 CIDR blocks allowed through the SQL server firewall. Only used when sqlPublicNetworkAccess is Enabled.')
param sqlFirewallRules firewallRule[] = []

@description('Max vCores for the serverless database.')
param sqlMaxVCores int

@description('Min vCores for the serverless database, as a string because Bicep has no decimal type (e.g. "0.5").')
param sqlMinVCores string

@description('Minutes of inactivity before the database auto-pauses. -1 disables auto-pause.')
param sqlAutoPauseDelayMinutes int

@description('Backup storage redundancy for the database.')
@allowed([
  'Local'
  'Zone'
  'Geo'
])
param sqlBackupStorageRedundancy string

@description('Whether the database uses the Azure SQL Database free offer: 100,000 vCore seconds, 32 GB of data and 32 GB of backup a month, for up to 10 General Purpose databases per subscription. Azure cannot convert an existing database to the free offer, so turning this on for a database that is already deployed has no effect.')
param sqlUseFreeLimit bool = false

@description('What happens when the free monthly limit runs out: AutoPause (stops until next month, no charge, but requires sqlMaxVCores <= 4 and sqlBackupStorageRedundancy Local) or BillOverage (stays up, excess billed, and cannot be switched back to AutoPause). Ignored when sqlUseFreeLimit is false.')
@allowed([
  'AutoPause'
  'BillOverage'
])
param sqlFreeLimitExhaustionBehavior string = 'AutoPause'

@description('User principal names (e.g. alice@contoso.com) of the members of the SQL admins group. This list replaces the group\'s membership.')
param sqlAdminMemberUpns array = []

@description('User principal names (e.g. bob@contoso.com) of the members of the SQL users group. This list replaces the group\'s membership; the function app\'s identity is always added.')
param sqlUserMemberUpns array = []

@description('Maximum number of instances the function app scales out to.')
param functionMaximumInstanceCount int

@description('Memory per function app instance in MB (512, 2048 or 4096).')
param functionInstanceMemoryMB int

var tags = {
  project: projectName
  environment: environmentName
  managedBy: 'bicep'
}

// Several resources need globally unique names, so add a suffix stable per resource group.
var uniqueSuffix = uniqueString(rg.id)

var sqlAdminsGroupName = 'grp_certdb_admins_${environmentName}'
var sqlUsersGroupName = 'grp_certdb_users_${environmentName}'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${projectName}-${environmentName}'
  location: location
  tags: tags
}

// Look up the Entra users listed for each group. The deployment fails if a UPN doesn't exist.
resource sqlAdminMembers 'Microsoft.Graph/users@v1.0' existing = [
  for upn in sqlAdminMemberUpns: {
    userPrincipalName: upn
  }
]

resource sqlUserMembers 'Microsoft.Graph/users@v1.0' existing = [
  for upn in sqlUserMemberUpns: {
    userPrincipalName: upn
  }
]

// Entra security groups are tenant-level objects, one pair per environment.
// Deleting an environment's resource group does not delete them.
resource sqlAdminsGroup 'Microsoft.Graph/groups@v1.0' = {
  uniqueName: sqlAdminsGroupName
  displayName: sqlAdminsGroupName
  description: 'Administrators of the certman ${environmentName} Azure SQL server.'
  mailEnabled: false
  mailNickname: sqlAdminsGroupName
  securityEnabled: true
  owners: {
    relationships: [
      deployer().objectId
    ]
  }
  members: {
    relationshipSemantics: 'replace'
    relationships: [for (upn, i) in sqlAdminMemberUpns: sqlAdminMembers[i].id]
  }
}

resource sqlUsersGroup 'Microsoft.Graph/groups@v1.0' = {
  uniqueName: sqlUsersGroupName
  displayName: sqlUsersGroupName
  description: 'Users of the certman ${environmentName} Azure SQL database.'
  mailEnabled: false
  mailNickname: sqlUsersGroupName
  securityEnabled: true
  owners: {
    relationships: [
      deployer().objectId
    ]
  }
  members: {
    relationshipSemantics: 'replace'
    // The listed users plus the function app's managed identity, which the app
    // signs in to the database as. Bicep can't concat a for-expression, so the
    // loop runs one past the users and the last slot is the identity.
    relationships: [
      for i in range(0, length(sqlUserMemberUpns) + 1): i < length(sqlUserMemberUpns)
        ? sqlUserMembers[i].id
        : functionApp.outputs.identityPrincipalId
    ]
  }
}

module network 'modules/network.bicep' = {
  scope: rg
  params: {
    location: location
    vnetName: 'vnet-${projectName}-${environmentName}'
    vnetAddressPrefix: vnetAddressPrefix
    privateEndpointsSubnetPrefix: privateEndpointsSubnetPrefix
    functionsSubnetPrefix: functionsSubnetPrefix
    tags: tags
  }
}

module sql 'modules/sql.bicep' = {
  scope: rg
  params: {
    location: location
    serverName: 'sql-${projectName}-${environmentName}-${uniqueSuffix}'
    databaseName: 'certdb'
    adminGroupName: sqlAdminsGroup.displayName
    adminGroupObjectId: sqlAdminsGroup.id
    publicNetworkAccess: sqlPublicNetworkAccess
    firewallRules: sqlFirewallRules
    maxVCores: sqlMaxVCores
    minVCores: sqlMinVCores
    autoPauseDelayMinutes: sqlAutoPauseDelayMinutes
    backupStorageRedundancy: sqlBackupStorageRedundancy
    useFreeLimit: sqlUseFreeLimit
    freeLimitExhaustionBehavior: sqlFreeLimitExhaustionBehavior
    vnetId: network.outputs.vnetId
    privateEndpointsSubnetId: network.outputs.privateEndpointsSubnetId
    tags: tags
  }
}

module functionApp 'modules/functionApp.bicep' = {
  scope: rg
  params: {
    location: location
    functionAppName: 'func-${projectName}-${environmentName}-${uniqueSuffix}'
    planName: 'plan-${projectName}-${environmentName}'
    identityName: 'id-func-${projectName}-${environmentName}'
    // Storage account names: 3-24 lowercase letters and digits.
    storageAccountName: take('st${projectName}${environmentName}${uniqueSuffix}', 24)
    logAnalyticsName: 'log-${projectName}-${environmentName}'
    appInsightsName: 'appi-${projectName}-${environmentName}'
    functionsSubnetId: network.outputs.functionsSubnetId
    sqlServerFqdn: sql.outputs.serverFqdn
    sqlDatabaseName: sql.outputs.databaseName
    maximumInstanceCount: functionMaximumInstanceCount
    instanceMemoryMB: functionInstanceMemoryMB
    tags: tags
  }
}

output resourceGroupName string = rg.name
output vnetName string = network.outputs.vnetName
output sqlServerName string = sql.outputs.serverName
output sqlServerFqdn string = sql.outputs.serverFqdn
output sqlDatabaseName string = sql.outputs.databaseName
output sqlAdminsGroupId string = sqlAdminsGroup.id
output sqlUsersGroupId string = sqlUsersGroup.id
output functionAppName string = functionApp.outputs.functionAppName
output functionAppHostName string = functionApp.outputs.functionAppHostName
