// Virtual network for certman: a subnet for private endpoints and one for the
// function app's outbound vnet integration.

param location string
param vnetName string
param vnetAddressPrefix string
param privateEndpointsSubnetPrefix string
param functionsSubnetPrefix string
param tags object

var privateEndpointsSubnetName = 'snet-private-endpoints'
var functionsSubnetName = 'snet-functions'

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: privateEndpointsSubnetName
        properties: {
          addressPrefix: privateEndpointsSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        // Flex Consumption vnet integration requires this delegation.
        name: functionsSubnetName
        properties: {
          addressPrefix: functionsSubnetPrefix
          delegations: [
            {
              name: 'flex-consumption'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output privateEndpointsSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, privateEndpointsSubnetName)
output functionsSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, functionsSubnetName)
