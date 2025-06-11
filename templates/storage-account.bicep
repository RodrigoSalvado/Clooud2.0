@description('Nome da Storage Account (must be globally unique, 3-24 caracteres, sem letras maiúsculas)')
param storageAccountName string

@description('Localização do recurso (por defeito, usa a location do resource group)')
param location string = resourceGroup().location

@description('Nome do container a criar')
param containerName string

@description('Ativar versioning de blob?')
param enableBlobVersioning bool = false

@description('Dias de retenção de soft delete de blob quando versioning ativado')
@minValue(1)
param blobSoftDeleteDays int = 7

resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    immutableStorageWithVersioning: {
      state: enableBlobVersioning ? 'Enabled' : 'Disabled'
    }
    deleteRetentionPolicy: {
      enabled: enableBlobVersioning
      days: enableBlobVersioning ? blobSoftDeleteDays : null
    }
    // Outras propriedades omitidas por simplicidade
  }
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2021-04-01' = {
  parent: storageAccount::blobServices::default
  name: containerName
  properties: {
    publicAccess: 'None'
  }
}
