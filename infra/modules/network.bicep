// Virtual network for certman. Starts with a subnet for private endpoints;
// add an integration subnet here when the function app is deployed.

param location string
param vnetName string
param vnetAddressPrefix string
param privateEndpointsSubnetPrefix string
param tags object

var privateEndpointsSubnetName = 'snet-private-endpoints'

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
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output privateEndpointsSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, privateEndpointsSubnetName)
