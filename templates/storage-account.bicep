@description('Nome da Storage Account (único globalmente)')
param storageAccountName string

@description('Localização do recurso (por defeito, usa a do Resource Group)')
param location string = resourceGroup().location

@description('Nome do container')
param containerName string

@description('Ativar versioning?')
param enableBlobVersioning bool = false

@description('Dias de soft delete se versioning ativado')
@minValue(1)
param blobSoftDeleteDays int = 7

resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2021-04-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    isVersioningEnabled: enableBlobVersioning
    deleteRetentionPolicy: {
      enabled: enableBlobVersioning
      days: enableBlobVersioning ? blobSoftDeleteDays : 0
    }
  }
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2021-04-01' = {
  parent: blobService
  name: containerName
  properties: {
    publicAccess: 'None'
  }
}
