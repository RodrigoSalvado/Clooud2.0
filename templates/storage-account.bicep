@description('Nome da Storage Account. Deve obedecer às regras: minúsculas, 3-24 caracteres, apenas letras e números.')
param storageAccountName string

@description('Nome do container Blob a criar.')
param containerName string

@description('Habilitar versioning de blobs?')
param enableBlobVersioning bool = false

@description('Dias de retenção para soft delete de blob. Se 0 ou omitido, desabilita.')
param blobSoftDeleteDays int = 0

// Usa a localização do resource group se não for passado
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
    // adicionar networkAcls, encryption, etc, conforme necessário
  }
}

// 2. Declarar o blobService "default" caso seja preciso configurar versioning / soft delete
var needsBlobServiceConfig = enableBlobVersioning || (blobSoftDeleteDays > 0)

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2022-09-01' = if (needsBlobServiceConfig) {
  parent: sa
  name: 'default'
  properties: {
    isVersioningEnabled: enableBlobVersioning
    deleteRetentionPolicy: {
      enabled: blobSoftDeleteDays > 0
      days: blobSoftDeleteDays
    }
  }
}

// 3. Declarar o container Blob como filho do blobService "default"
resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01' = {
  parent: sa  // aparent deve apontar para o blobService, mas Bicep permite parent: sa e name: 'default/<containerName>' ou parent: blobService e name: containerName. Vamos usar parent: blobService se exist, ou parent: sa com name qualificado.
  // Duas abordagens:
  // A) Se precisamos condicionalmente usar blobService (quando needsBlobServiceConfig=false, blobService não existe):
  //    parent: sa
  //    name: 'default/${containerName}'
  // B) Se blobService existe, parent: blobService e name: containerName.
  // Podemos usar uma condição ternária para definir parent e name corretamente.
  name: needsBlobServiceConfig ? '${blobService.name}/${containerName}' : 'default/${containerName}'
  properties: {
    publicAccess: 'None'
  }
  dependsOn: [
    sa
    // se precisar de garantir blobService antes, blobService está incluído implicitamente se name usar blobService.name
  ]
}

// Saídas
output storageAccountId string = sa.id
output blobContainerId string = blobContainer.id
