@description('Nome da Web App')
param webAppName string

@description('Localização (default resourceGroup().location)')
param location string = resourceGroup().location

@description('Nome do App Service Plan existente')
param planName string

@description('Imagem Docker a usar, ex: "meuuser/minha-app:latest"')
param imageName string

@description('Token SAS para Storage (opcional). Se vazio, não adiciona.')
param containerSasToken string = ''

@description('Nome da Storage Account (opcional). Se vazio, não adiciona.')
param storageAccountName string = ''

@description('Nome do container no Storage (opcional). Se vazio, não adiciona.')
param containerName string = ''

@description('URL do registry privado, ex: "https://myregistry.azurecr.io" (opcional). Se vazio, não adiciona.')
param containerRegistryUrl string = ''

@description('Username do registry (opcional).')
param containerRegistryUsername string = ''

@description('Password do registry (opcional).')
param containerRegistryPassword string = ''

@description('Criar Role Assignment para a Web App Managed Identity na Storage Account?')
param createRoleAssignment bool = false

// Base de appSettings
var baseAppSettings = [
  {
    name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
    value: 'false'
  }
]

// AppSettings para Storage SAS, se fornecido
var storageSettings = (containerSasToken != '') ? [
  {
    name: 'STORAGE_SAS_TOKEN'
    value: containerSasToken
  }
  {
    name: 'STORAGE_ACCOUNT_NAME'
    value: storageAccountName
  }
  {
    name: 'CONTAINER_NAME'
    value: containerName
  }
] : []

// AppSettings para registry privado, se fornecido
var registrySettings = (containerRegistryUrl != '') ? [
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
] : []

resource webApp 'Microsoft.Web/sites@2022-03-01' = {
  name: webAppName
  location: location
  kind: 'app,linux,container'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: resourceId('Microsoft.Web/serverfarms', planName)
    siteConfig: {
      // Usa string interpolation para a Docker image
      linuxFxVersion: 'DOCKER|' + imageName
      appSettings: concat(
        baseAppSettings,
        storageSettings,
        registrySettings
      )
    }
  }
}

// Se precisares de criar Role Assignment na Storage Account
resource storageAccountForRole 'Microsoft.Storage/storageAccounts@2022-09-01' existing = if (createRoleAssignment && storageAccountName != '') {
  name: storageAccountName
}

// A principalId da identidade do Web App
var principalId = webApp.identity.principalId

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = if (createRoleAssignment && storageAccountName != '') {
  name: guid(storageAccountForRole.id, principalId, 'StorageBlobDataContributor')
  scope: storageAccountForRole
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe') // Storage Blob Data Contributor
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
