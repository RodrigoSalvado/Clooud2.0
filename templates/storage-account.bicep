targetScope = 'resourceGroup'

// Parâmetros
@minLength(3)
@maxLength(24)
@description('Nome da Storage Account (entre 3 e 24 caracteres, minúsculas e dígitos; sem pontos).')
param storageAccountName string = 'miniprojetostorage20'

@minLength(3)
@maxLength(63)
@description('Nome do Blob Container (entre 3 e 63 caracteres; minúsculas, dígitos e traços permitidos).')
param containerName string = 'reddit-posts'

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
  'BlobStorage'
  'Storage'
])
@description('Kind da Storage Account')
param kind string = 'StorageV2'

@allowed([
  'Hot'
  'Cool'
])
@description('Access tier (aplica-se a StorageV2 para blob)')
param accessTier string = 'Hot'

@description('Forçar apenas tráfego HTTPS')
param allowHttpsTrafficOnly bool = true

@description('Habilitar versioning em blobs')
param enableBlobVersioning bool = false

@description('Habilitar soft delete para blobs em dias (0 desativa)')
param blobSoftDeleteDays int = 0

@description('DefaultAction para network rules: Allow ou Deny')
param defaultAction string = 'Allow'

@description('Lista de CIDR ou IPs para permitir; vazio = acesso público (menos restrito)')
param allowedNetworkRules array = []

// 1. Storage Account
resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: skuName
  }
  kind: kind
  properties: {
    accessTier: accessTier
    supportsHttpsTrafficOnly: allowHttpsTrafficOnly
    isVersioningEnabled: enableBlobVersioning
    deleteRetentionPolicy: {
      enabled: blobSoftDeleteDays > 0
      days: blobSoftDeleteDays > 0 ? blobSoftDeleteDays : 0
    }
    networkAcls: {
      defaultAction: defaultAction
      bypass: 'AzureServices'
      ipRules: [
        for rule in allowedNetworkRules: {
          value: rule
        }
      ]
      virtualNetworkRules: []
    }
  }
}

// 2. Blob service
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2021-04-01' = {
  name: 'default'
  parent: storageAccount
}

// 3. Container
resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2021-04-01' = {
  name: containerName
  parent: blobService
  properties: {
    publicAccess: 'None'
  }
}

// Outputs
output storageAccountId string = storageAccount.id
output storageAccountEndpoints object = {
  blob: storageAccount.properties.primaryEndpoints.blob
  file: storageAccount.properties.primaryEndpoints.file
  queue: storageAccount.properties.primaryEndpoints.queue
  table: storageAccount.properties.primaryEndpoints.table
}
output blobContainerName string = blobContainer.name
