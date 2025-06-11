targetScope = 'resourceGroup'

// Parâmetros
@minLength(1)
@maxLength(40)
@description('Nome do App Service Plan existente. Ex.: "ASP-MiniProjetoCloud2.0".')
param planName string = 'ASP-MiniProjetoCloud2.0'

@minLength(2)
@maxLength(60)
@description('Nome do Web App (globalmente único).')
param webAppName string

@description('Localização. Por defeito, usa a localização do Resource Group.')
param location string = resourceGroup().location

@description('Nome da imagem Docker a usar, no formato "repository/image:tag".')
param imageName string = 'rodrig0salv/minha-app:latest'

@description('Se a imagem estiver num registo privado, passa aqui o URL; caso seja pública, deixa vazio.')
param containerRegistryUrl string = ''
@description('Username para o registo privado; caso público, deixa vazio.')
param containerRegistryUsername string = ''
@secure()
@description('Password/secreto para o registo privado; caso público, deixa vazio.')
param containerRegistryPassword string = ''

@secure()
@description('SAS token para o container, sem "?" inicial.')
param containerSasToken string

// Parâmetros para montar URL completa do container com SAS (opcional)
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

// URL completa do container com SAS, usando environment().suffixes.storage para evitar hardcode
var blobEndpointSuffix = environment().suffixes.storage
var urlWithSas = 'https://${storageAccountName}.blob${blobEndpointSuffix}/${containerName}?${containerSasToken}'
var urlSetting = [
  {
    name: 'CONTAINER_URL_WITH_SAS'
    value: urlWithSas
  }
]

// Combina appSettings
var appSettingsCombined = concat(registrySettings, sasSettings, portSetting, urlSetting)

// Web App para container Docker
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