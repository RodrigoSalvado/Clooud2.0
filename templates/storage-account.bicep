param storageAccountName string
param containerName string
param enableBlobVersioning bool = false
param blobSoftDeleteDays int = 0
param location string = resourceGroup().location

resource sa 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01' = {
  parent: sa
  name: 'default/${containerName}'
  properties: {
    publicAccess: 'None'
  }
  dependsOn: [
    sa
  ]
}

var configureVersioning = enableBlobVersioning
var configureSoftDelete = blobSoftDeleteDays > 0

resource bs 'Microsoft.Storage/storageAccounts/blobServices@2022-09-01' = if (configureVersioning || configureSoftDelete) {
  parent: sa
  name: 'default'
  properties: {
    isVersioningEnabled: configureVersioning
    deleteRetentionPolicy: configureSoftDelete ? {
      enabled: true
      days: blobSoftDeleteDays
    } : {
      enabled: false
    }
  }
  dependsOn: [
    sa
  ]
}

output storageAccountId string = sa.id
output blobContainerId string = blobContainer.id
