@description('Nome do Web App a criar.')
param webAppName string

@description('Nome do App Service Plan existente (deve já existir ou ter sido criado noutro template).')
param planName string

@description('Nome completo da imagem Docker, ex: "meu-registo/minha-app:latest".')
param imageName string

@description('Se a imagem Docker estiver em registry privado, a URL do registry (ex: "myregistry.azurecr.io"). Se for imagem pública (Docker Hub), deixe vazio.')
param containerRegistryUrl string = ''

@secure()
@description('Username para o container registry privado. Se não usar registry privado, deixe vazio.')
param containerRegistryUsername string = ''

@secure()
@description('Password ou secret para o container registry privado. Se não usar registry privado, deixe vazio.')
param containerRegistryPassword string = ''

@description('Nome da Storage Account para a qual o Web App precisará de acesso. Se não usar Storage, deixe vazio.')
param storageAccountName string = ''

@description('Nome do container Blob dentro da Storage Account. Se não usar Storage, deixe vazio.')
param containerName string = ''

@secure()
@description('SAS token (sem “?”) para aceder ao container Blob. Se não usar Storage ou usar outra forma, deixe vazio.')
param containerSasToken string = ''

@description('Se true, o template tentará criar um Role Assignment para dar ao Web App acesso à Storage Account. Se não usar Storage ou não quiser atribuir via template, passe false.')
param createStorageRoleAssignment bool = false

@description('Localização; por defeito, usa a localização do resource group.')
param location string = resourceGroup().location

// ===== Referência ao App Service Plan existente =====
resource asp 'Microsoft.Web/serverfarms@2022-03-01' existing = {
  name: planName
}

// ===== Variáveis para App Settings =====
// Para registry privado, definimos três settings padrão usados pelo Web App para registos privados:
var registrySettings = empty(containerRegistryUrl) ? [] : [
  {
    name: 'DOCKER_REGISTRY_SERVER_URL'
    value: containerRegistryUrl
  }
  {
    name: 'DOCKER_REGISTRY_SERVER_USERNAME'
    value: containerRegistryUsername
  }
  {
    name: 'DOCKER_REGISTRY_SERVER_PASSWORD'
    value: containerRegistryPassword
  }
]

// Para Storage via SAS, definimos settings (exemplo):
var storageSettings = empty(storageAccountName) ? [] : [
  {
    name: 'STORAGE_ACCOUNT_NAME'
    value: storageAccountName
  }
  {
    name: 'CONTAINER_NAME'
    value: containerName
  }
  {
    name: 'SAS_TOKEN'
    value: containerSasToken
  }
]

// Concatena ambas listas; se uma delas for vazia, concat apenas devolve a outra.
var appSettingsList = concat(registrySettings, storageSettings)

// ===== Criação do Web App =====
resource webApp 'Microsoft.Web/sites@2022-03-01' = {
  name: webAppName
  location: location
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: asp.id
    siteConfig: {
      // Define a imagem Docker
      linuxFxVersion: 'DOCKER|${imageName}'
      // Aplica App Settings apenas se algum existir (lista vazia é permitida)
      appSettings: appSettingsList
    }
  }
}

// ===== Role Assignment para Storage Account (opcional) =====
/*
   Se createStorageRoleAssignment == true E storageAccountName não vazio,
   faz referência à Storage Account existente e atribui role "Storage Blob Data Contributor"
   ao principal do Web App.
*/
resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' existing = if (createStorageRoleAssignment && !empty(storageAccountName)) {
  name: storageAccountName
}

var storageAccountId = createStorageRoleAssignment && !empty(storageAccountName) ? storageAccount.id : ''
// RoleDefinitionId do Storage Blob Data Contributor
var storageBlobContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
// Nome determinístico para o Role Assignment
var roleAssignmentName = createStorageRoleAssignment && !empty(storageAccountName) ? guid(webApp.id, storageAccountId, 'StorageBlobDataContributor') : '00000000-0000-0000-0000-000000000000'

resource storageBlobRoleAssignment 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = if (createStorageRoleAssignment && !empty(storageAccountName)) {
  name: roleAssignmentName
  scope: storageAccount
  properties: {
    roleDefinitionId: storageBlobContributorRoleId
    principalId: webApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
  dependsOn: [
    webApp
  ]
}

// ===== Outputs opcionais =====
output webAppHostname string = webApp.properties.defaultHostName
output webAppId string = webApp.id
output principalId string = webApp.identity.principalId
