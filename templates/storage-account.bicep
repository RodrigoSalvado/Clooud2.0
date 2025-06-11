@description('Nome da Storage Account (único globalmente, 3-24 caracteres, minúsculas e números)')
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

// Cria a Storage Account
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
    supportsHttpsTrafficOnly: true
    // Outros blocos (networkAcls, encryption, etc.) podem ser adicionados aqui se necessário
  }
}

// Configuração de versioning e soft delete no serviço de blob
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

// Container dentro do blob service
resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2021-04-01' = {
  parent: blobService
  name: containerName
  properties: {
    publicAccess: 'None'
  }
}
