targetScope = 'resourceGroup'

// Parâmetros
@minLength(1)
@maxLength(40)
param planName string = 'ASP-MiniProjetoCloud2.0'

@minLength(2)
@maxLength(60)
param webAppName string

param location string = resourceGroup().location

param imageName string = 'rodrig0salv/minha-app:latest'

param containerRegistryUrl string = ''
param containerRegistryUsername string = ''
@secure()
param containerRegistryPassword string = ''

@secure()
param containerSasToken string

@minLength(3)
@maxLength(24)
@description('Nome da Storage Account onde está o container. Ex.: "miniprojetostorage20".')
param storageAccountName string

@minLength(3)
@maxLength(63)
@description('Nome do container de blobs. Ex.: "reddit-posts".')
param containerName string = 'reddit-posts'

// Referenciar o App Service Plan existente
resource existingPlan 'Microsoft.Web/serverfarms@2022-03-01' existing = {
  name: planName
}

// Preparar arrays condicionais para appSettings
var registrySettings = (containerRegistryUrl != '' && containerRegistryUsername != '' && containerRegistryPassword != '') ? [
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

var sasSettings = [
  {
    name: 'CONTAINER_SAS_TOKEN'
    value: containerSasToken
  }
]

// Porta do Flask
var portSetting = [
  {
    name: 'WEBSITES_PORT'
    value: '5000'
  }
]

// Montar URL completa do container usando environment() para suffix
// environment().suffixes.storageEndpoint devolve algo como ".core.windows.net"
var blobEndpointSuffix = environment().suffixes.storageEndpoint
var urlWithSas = 'https://${storageAccountName}.blob${blobEndpointSuffix}/${containerName}?${containerSasToken}'
var urlSetting = [
  {
    name: 'CONTAINER_URL_WITH_SAS'
    value: urlWithSas
  }
]

// Combina appSettings
var appSettingsCombined = concat(registrySettings, sasSettings, portSetting, urlSetting)

resource webApp 'Microsoft.Web/sites@2022-03-01' = {
  name: webAppName
  location: location
  kind: 'app,linux'
  properties: {
    serverFarmId: existingPlan.id
    siteConfig: {
      linuxFxVersion: 'DOCKER|${imageName}'
      alwaysOn: true
      appSettings: appSettingsCombined
    }
  }
  dependsOn: [
    existingPlan
  ]
}

output webAppDefaultHostName string = webApp.properties.defaultHostName
output webAppResourceId string = webApp.id
