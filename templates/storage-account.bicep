@description('Nome da Storage Account. Deve ter entre 3 e 24 caracteres, apenas minúsculas e números.')
param storageAccountName string

@description('Nome do container Blob a criar.')
param containerName string

@description('Habilitar versioning de blobs?')
param enableBlobVersioning bool = false

@description('Dias de retenção para soft delete de blobs. Se 0 ou queres desabilitar, pode deixar 0.')
param blobSoftDeleteDays int = 0

@description('Localização; por defeito usa a localização do resource group.')
param location string = resourceGroup().location

// 1. Cria a Storage Account
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
    // se quiseres networkAcls, encryption, etc, adiciona aqui
  }
}

// 2. Blob Service "default" (para configurar versioning e soft delete)
//    Declaramos sempre, mas se não quiseres versioning nem soft delete,
//    properties.isVersioningEnabled ficará false e deleteRetentionPolicy.enabled=false.
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2022-09-01' = {
  parent: sa
  name: 'default'
  properties: {
    isVersioningEnabled: enableBlobVersioning
    deleteRetentionPolicy: {
      enabled: blobSoftDeleteDays > 0
      // Se blobSoftDeleteDays = 0, o enabled fica false e o valor de days será ignorado.
      // Mas para satisfazer o esquema, usamos max(blobSoftDeleteDays, 1). Quando enabled=false, days não tem efeito.
      days: max(blobSoftDeleteDays, 1)
    }
  }
}

// 3. Container Blob como filho do blobService 'default'
resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01' = {
  parent: blobService
  name: containerName
  properties: {
    publicAccess: 'None'
  }
}

// 4. Outputs (opcional)
output storageAccountId string = sa.id
output blobContainerId string = blobContainer.id
