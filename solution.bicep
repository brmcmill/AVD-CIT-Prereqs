targetScope = 'subscription'

@description('The name of the compute gallery for managing the images.')
param computeGalleryName string

@description('The name of the deployment script for configuring an existing subnet.')
param deploymentScriptName string

@description('The name of an existing resource group.')
param existingResourceGroupName string

@description('The resource ID of an existing virtual network.')
param existingVirtualNetworkResourceId string = ''

@description('Indicates whether the image definition supports accelerated networking.')
param imageDefinitionIsAcceleratedNetworkSupported bool

@description('Indicates whether the image definition supports hibernation.')
param imageDefinitionIsHibernateSupported bool

@description('The name of the Image Definition for the Shared Image Gallery.')
param imageDefinitionName string

@allowed([
  'ConfidentialVM'
  'ConfidentialVMSupported'
  'Standard'
  'TrustedLaunch'
])
@description('The security type for the Image Definition.')
param imageDefinitionSecurityType string

@description('The offer of the marketplace image.')
param imageOffer string

@description('The publisher of the marketplace image.')
param imagePublisher string

@description('The SKU of the marketplace image.')
param imageSku string

@description('The location for the resources deployed in this solution.')
param location string = deployment().location

@description('The name of the resource group for the resources.')
param resourceGroupName string

@description('The name of the storage account for the imaging artifacts.')
param storageAccountName string

@description('The subnet name of an existing virtual network.')
param subnetName string

@description('The key-value pairs of tags for the resources.')
param tags object = {}

@description('DO NOT MODIFY THIS VALUE! The timestamp is needed to differentiate deployments for certain Azure resources and must be set using a parameter.')
param timestamp string = utcNow('yyyyMMddhhmmss')

@description('The name for the user assigned identity')
param userAssignedIdentityName string

var Roles = [
  {
    resourceGroup: split(existingVirtualNetworkResourceId, '/')[4]
    name: 'Virtual Network Join'
    description: 'Allow resources to join a subnet'
    permissions: [
      {
        actions: [
          'Microsoft.Network/virtualNetworks/read'
          'Microsoft.Network/virtualNetworks/subnets/read'
          'Microsoft.Network/virtualNetworks/subnets/join/action'
          'Microsoft.Network/virtualNetworks/subnets/write' // Required to update the private link network policy
        ]
      }
    ]
  }
  {
    resourceGroup: resourceGroupName
    name: 'Image Template Contributor'
    description: 'Allow the creation and management of images'
    permissions: [
      {
        actions: [
          'Microsoft.Compute/galleries/read'
          'Microsoft.Compute/galleries/images/read'
          'Microsoft.Compute/galleries/images/versions/read'
          'Microsoft.Compute/galleries/images/versions/write'
          'Microsoft.Compute/images/read'
          'Microsoft.Compute/images/write'
          'Microsoft.Compute/images/delete'
        ]
      }
    ]
  }
]

resource rg_existing 'Microsoft.Resources/resourceGroups@2019-10-01' existing = if (!empty(existingResourceGroupName)) {
  name: existingResourceGroupName
}

resource rg 'Microsoft.Resources/resourceGroups@2019-10-01' = if (empty(existingResourceGroupName)) {
  name: resourceGroupName
  location: location
  tags: contains(tags, 'Microsoft.Resources/resourceGroups') ? tags['Microsoft.Resources/resourceGroups'] : {}
  properties: {}
}

resource roleDefinitions 'Microsoft.Authorization/roleDefinitions@2015-07-01' = [for i in range(0, length(Roles)): {
  name: guid(Roles[i].name, subscription().id)
  properties: {
    roleName: '${Roles[i].name} (${subscription().subscriptionId})'
    description: Roles[i].description
    permissions: Roles[i].permissions
    assignableScopes: [
      subscription().id
    ]
  }
}]

module userAssignedIdentity 'modules/userAssignedIdentity.bicep' = {
  name: 'UserAssignedIdentity_${timestamp}'
  scope: empty(existingResourceGroupName) ? rg : rg_existing
  params: {
    location: location
    name: userAssignedIdentityName
    tags: tags
  }
}

@batchSize(1)
module roleAssignments 'modules/roleAssignment.bicep' = [for i in range(0, length(Roles)): {
  name: 'RoleAssignments_${i}_${timestamp}'
  scope: resourceGroup(Roles[i].resourceGroup)
  params: {
    principalId: userAssignedIdentity.outputs.PrincipalId
    roleDefinitionId: roleDefinitions[i].id
  }
}]

module computeGallery 'modules/computeGallery.bicep' = {
  name: 'ComputeGallery_${timestamp}'
  scope: empty(existingResourceGroupName) ? rg : rg_existing
  params: {
    computeGalleryName: computeGalleryName
    imageDefinitionName: imageDefinitionName
    imageDefinitionSecurityType: imageDefinitionSecurityType
    imageOffer: imageOffer
    imagePublisher: imagePublisher
    imageSku: imageSku
    location: location
    tags: tags
    imageDefinitionIsAcceleratedNetworkSupported: imageDefinitionIsAcceleratedNetworkSupported
    imageDefinitionIsHibernateSupported: imageDefinitionIsHibernateSupported
  }
}

module networkPolicy 'modules/networkPolicy.bicep' = if (!(empty(subnetName)) && !(empty(existingVirtualNetworkResourceId))) {
  name: 'NetworkPolicy_${timestamp}'
  scope: empty(existingResourceGroupName) ? rg : rg_existing
  params: {
    deploymentScriptName: deploymentScriptName
    location: location
    subnetName: subnetName
    tags: tags
    timestamp: timestamp
    userAssignedIdentityResourceId: userAssignedIdentity.outputs.ResourceId
    virtualNetworkName: split(existingVirtualNetworkResourceId, '/')[8]
    virtualNetworkResourceGroupName: split(existingVirtualNetworkResourceId, '/')[4]
  }
  dependsOn: [
    roleAssignments
  ]
}

module storage 'modules/storageAccount.bicep' = {
  name: 'StorageAccount_${timestamp}'
  scope: empty(existingResourceGroupName) ? rg : rg_existing
  params: {
    location: location
    storageAccountName: storageAccountName
    tags: tags
    userAssignedIdentityPrincipalId: userAssignedIdentity.outputs.PrincipalId
    userAssignedIdentityResourceId: userAssignedIdentity.outputs.ResourceId
  }
}
