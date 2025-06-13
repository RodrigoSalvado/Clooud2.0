@description('Nome do Web App a criar/atualizar')
param webAppName string

@description('Nome do App Service Plan existente (deve já existir no mesmo resource group) ou que será referenciado')
param planName string

@description('Nome da imagem Docker, no formato <registry>/<repository>:<tag>, ex: "rodrig0salv/minha-app:latest"')
param imageName string

@description('URL do registry Docker (ex: https://index.docker.io ou URL do container registry). Se vazio, considera imagem pública no Docker Hub.')
param containerRegistryUrl string = ''

@description('Username para o registry. Se containerRegistryUrl vazio, pode ser deixado em branco.')
param containerRegistryUsername string = ''

@secure()
@description('Password para o registry. Se containerRegistryUrl vazio, pode ser deixado em branco.')
param containerRegistryPassword string = ''

@description('Nome da Storage Account para uso pela aplicação (apenas para app settings).')
param storageAccountName string

@description('Nome do container dentro da Storage Account (apenas para app settings).')
param containerName string

@description('SAS token a usar no acesso ao container (apenas para app settings).')
param containerSasToken string

@description('URL da Function (SearchFunction) com a master key, para armazenar no app setting FUNCTION_URL. Se vazio, não será adicionado.')
param functionUrl string = ''

@description('Lista de origens permitidas para CORS. Use ["*"] para permitir todas as origens (cuidado com segurança).')
param allowedCorsOrigins array = []

// Variáveis auxiliares para condições
var usePrivateRegistry = containerRegistryUrl != ''
var addFunctionUrl = functionUrl != ''

// Referência ao App Service Plan existente
resource appServicePlan 'Microsoft.Web/serverfarms@2021-02-01' existing = {
  name: planName
}

// Define arrays de appSettings
var baseAppSettings = [
  {
    name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
    value: 'false'
  }
  {
    name: 'STORAGE_ACCOUNT_NAME'
    value: storageAccountName
  }
  {
    name: 'CONTAINER_NAME'
    value: containerName
  }
  {
    name: 'CONTAINER_SAS_TOKEN'
    value: containerSasToken
  }
]

var privateRegistrySettings = usePrivateRegistry ? [
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

var functionUrlSettings = addFunctionUrl ? [
  {
    name: 'FUNCTION_URL'
    value: functionUrl
  }
] : []

// Criação / atualização do Web App Linux em container
resource webApp 'Microsoft.Web/sites@2021-03-01' = {
  name: webAppName
  location: resourceGroup().location
  kind: 'app,linux'
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'DOCKER|${imageName}'
      alwaysOn: true

      cors: {
        allowedOrigins: allowedCorsOrigins
      }

      appSettings: baseAppSettings + privateRegistrySettings + functionUrlSettings

      http20Enabled: true
    }
  }
}

// Saída opcional: hostname padrão do Web App
output defaultHostName string = webApp.properties.defaultHostName
