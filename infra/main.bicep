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

@description('User principal names (e.g. alice@contoso.com) of the members of the SQL admins group. This list replaces the group\'s membership.')
param sqlAdminMemberUpns array = []

@description('User principal names (e.g. bob@contoso.com) of the members of the SQL users group. This list replaces the group\'s membership.')
param sqlUserMemberUpns array = []

var tags = {
  project: projectName
  environment: environmentName
  managedBy: 'bicep'
}

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
    relationships: [for (upn, i) in sqlUserMemberUpns: sqlUserMembers[i].id]
  }
}

module network 'modules/network.bicep' = {
  scope: rg
  params: {
    location: location
    vnetName: 'vnet-${projectName}-${environmentName}'
    vnetAddressPrefix: vnetAddressPrefix
    privateEndpointsSubnetPrefix: privateEndpointsSubnetPrefix
    tags: tags
  }
}

module sql 'modules/sql.bicep' = {
  scope: rg
  params: {
    location: location
    // Server names are globally unique, so add a suffix stable per resource group.
    serverName: 'sql-${projectName}-${environmentName}-${uniqueString(rg.id)}'
    databaseName: 'certdb'
    adminGroupName: sqlAdminsGroup.displayName
    adminGroupObjectId: sqlAdminsGroup.id
    publicNetworkAccess: sqlPublicNetworkAccess
    firewallRules: sqlFirewallRules
    maxVCores: sqlMaxVCores
    minVCores: sqlMinVCores
    autoPauseDelayMinutes: sqlAutoPauseDelayMinutes
    backupStorageRedundancy: sqlBackupStorageRedundancy
    vnetId: network.outputs.vnetId
    privateEndpointsSubnetId: network.outputs.privateEndpointsSubnetId
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
