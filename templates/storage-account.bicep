targetScope = 'resourceGroup'

// Parâmetros
@minLength(3)
@maxLength(24)
@description('Nome da Storage Account (entre 3 e 24 caracteres, minúsculas e dígitos; sem pontos).')
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
@description('Access tier (aplica-se a StorageV2 para blob)')
param accessTier string = 'Hot'

@description('Forçar apenas tráfego HTTPS')
param allowHttpsTrafficOnly bool = true

@description('Habilitar versioning em blobs? Se true, configuramos via child resource blobServices.')
param enableBlobVersioning bool = false

@description('Número de dias para soft delete de blobs. Se 0 ou negativo, não configuramos soft delete.')
param blobSoftDeleteDays int = 0

@description('DefaultAction para network rules: Allow ou Deny')
param defaultAction string = 'Allow'

@description('Lista de CIDR ou IPs para permitir; vazio = acesso público (menos restrito)')
param allowedNetworkRules array = []

@minLength(3)
@maxLength(63)
@description('Nome do Blob Container (entre 3 e 63 caracteres; minúsculas, dígitos e traços permitidos).')
param containerName string

// 1. Criar ou atualizar a Storage Account
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
    // Outras propriedades permitidas podem ser adicionadas aqui, se necessário
  }
}

// 2. Configurar versioning e soft delete via recurso filho blobServices, se solicitado
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2021-04-01' = if (enableBlobVersioning || blobSoftDeleteDays > 0) {
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

// 3. Criar o container como child resource de storageAccount
//    Usamos name = 'default/${containerName}' e parent = storageAccount
resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2021-04-01' = {
  name: 'default/${containerName}'
  parent: storageAccount
  properties: {
    publicAccess: 'None'
  }
  // Dependência implícita em storageAccount; se blobService existir, o Azure aplica as configurações de versioning/soft delete antes
}

// Outputs úteis
output storageAccountId string = storageAccount.id
output storageAccountEndpoints object = {
  blob: storageAccount.properties.primaryEndpoints.blob
  file: storageAccount.properties.primaryEndpoints.file
  queue: storageAccount.properties.primaryEndpoints.queue
  table: storageAccount.properties.primaryEndpoints.table
}
output blobContainerName string = containerName
