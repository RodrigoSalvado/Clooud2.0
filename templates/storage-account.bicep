targetScope = 'resourceGroup'

@minLength(3)
@maxLength(24)
@description('Nome da Storage Account (entre 3 e 24 caracteres, minúsculas e dígitos).')
param storageAccountName string

@description('Localização. Por defeito, usa a localização do Resource Group.')
param location string = resourceGroup().location

@allowed([
  'Standard_LRS'
  'Standard_GRS'
  'Standard_RAGRS'
  'Standard_ZRS'
  'Premium_LRS'
])
@description('SKU da Storage Account')
param skuName string = 'Standard_LRS'

@allowed([
  'StorageV2'
])
@description('Kind da Storage Account. Geralmente StorageV2.')
param kind string = 'StorageV2'

@allowed([
  'Hot'
  'Cool'
])
@description('Access tier (aplica-se a StorageV2)')
param accessTier string = 'Hot'

@description('Forçar apenas tráfego HTTPS')
param allowHttpsTrafficOnly bool = true

@description('Habilitar versioning em blobs?')
param enableBlobVersioning bool = false

@description('Dias de soft delete para blobs. Se <= 0, não configura.')
param blobSoftDeleteDays int = 0

@description('DefaultAction para network rules: Allow ou Deny')
param defaultAction string = 'Allow'

@description('Lista de CIDR ou IPs para permitir; vazio = mais aberto')
param allowedNetworkRules array = []

@minLength(3)
@maxLength(63)
@description('Nome do Blob Container (entre 3 e 63 caracteres; minúsculas, dígitos e traços).')
param containerName string

resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageAccountName
  location: location
  sku: { name: skuName }
  kind: kind
  properties: {
    accessTier: accessTier
    supportsHttpsTrafficOnly: allowHttpsTrafficOnly
    networkAcls: {
      defaultAction: defaultAction
      bypass: 'AzureServices'
      ipRules: [ for rule in allowedNetworkRules: { value: rule } ]
      virtualNetworkRules: []
    }
  }
}

resource blobServiceUpdate 'Microsoft.Storage/storageAccounts/blobServices@2021-04-01' = if (enableBlobVersioning || blobSoftDeleteDays > 0) {
  name: 'default'
  parent: storageAccount
  properties: {
    isVersioningEnabled: enableBlobVersioning
    deleteRetentionPolicy: {
      enabled: blobSoftDeleteDays > 0
      days: blobSoftDeleteDays > 0 ? blobSoftDeleteDays : 0
    }
  }
}

resource blobServiceExisting 'Microsoft.Storage/storageAccounts/blobServices@2021-04-01' existing = {
  name: 'default'
  parent: storageAccount
}

resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2021-04-01' = {
  name: containerName
  parent: blobServiceExisting
  properties: { publicAccess: 'None' }
}

output storageAccountId string = storageAccount.id
output blobContainerName string = containerName