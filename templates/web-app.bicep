targetScope = 'resourceGroup'

@minLength(1)
@maxLength(40)
@description('Nome do App Service Plan existente.')
param planName string = 'ASP-MiniProjetoCloud2.0'

@minLength(2)
@maxLength(60)
@description('Nome do Web App (globalmente único).')
param webAppName string

@description('Localização. Por defeito, usa a localização do Resource Group.')
param location string = resourceGroup().location

@description('Nome da imagem Docker a usar, ex.: "rodrig0salv/minha-app:latest".')
param imageName string = 'rodrig0salv/minha-app:latest'

@description('Se a imagem Docker estiver num registo privado, passa aqui o URL; caso público, deixa vazio.')
param containerRegistryUrl string = ''
@description('Username para registo privado; caso público, deixa vazio.')
param containerRegistryUsername string = ''
@secure()
@description('Password/secreto para registo privado; caso público, deixa vazio.')
param containerRegistryPassword string = ''

@secure()
@description('Opcional: SAS token para o container de Storage, sem "?" inicial. Se usar Managed Identity, podes passar vazio.')
param containerSasToken string = ''

@minLength(3)
@maxLength(24)
@description('Nome da Storage Account usada no Private Endpoint ou para montar URL completa, ex.: "miniprojetostorage20".')
param storageAccountName string = 'miniprojetostorage20'

@minLength(3)
@maxLength(63)
@description('Nome do container em Storage Account, ex.: "reddit-posts".')
param containerName string = 'reddit-posts'

@minLength(1)
@maxLength(40)
@description('Nome da VNet existente para VNet Integration.')
param vnetName string = 'myVNet'

@minLength(1)
@maxLength(24)
@description('Nome da subnet privada na VNet para VNet Integration (Regional).')
param subnetName string = 'private-subnet'

resource existingPlan 'Microsoft.Web/serverfarms@2022-03-01' existing = { name: planName }

resource webApp 'Microsoft.Web/sites@2022-03-01' = {
  name: webAppName
  location: location
  kind: 'app,linux'
  properties: {
    serverFarmId: existingPlan.id
    siteConfig: {
      linuxFxVersion: 'DOCKER|${imageName}'
      alwaysOn: true
      appSettings: concat(
        (containerRegistryUrl != '' && containerRegistryUsername != '' && containerRegistryPassword != '') ? [
          { name: 'DOCKER_REGISTRY_SERVER_URL'; value: containerRegistryUrl }
          { name: 'DOCKER_REGISTRY_SERVER_USERNAME'; value: containerRegistryUsername }
          { name: 'DOCKER_REGISTRY_SERVER_PASSWORD'; value: containerRegistryPassword }
        ] : [],
        [ { name: 'WEBSITES_PORT'; value: '5000' } ],
        (containerSasToken != '') ? [ { name: 'CONTAINER_SAS_TOKEN'; value: containerSasToken } ] : [],
        (containerSasToken != '') ? [ { name: 'CONTAINER_URL_WITH_SAS'; value: 'https://${storageAccountName}.blob${environment().suffixes.storage}/${containerName}?${containerSasToken}' } ] : []
      )
    }
  }
  dependsOn: [ existingPlan ]
}

resource vnetIntegration 'Microsoft.Web/sites/virtualNetworkConnections@2021-03-01' = {
  parent: webApp
  name: subnetName
  properties: {
    vnetResourceId: resourceId('Microsoft.Network/virtualNetworks', vnetName)
  }
}

resource assignIdentity 'Microsoft.Web/sites@2022-03-01' = {
  name: webAppName
  properties: { identity: { type: 'SystemAssigned' } }
  dependsOn: [ webApp ]
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = {
  name: guid(storageAccountName, 'StorageBlobDataContributor', webApp.identity.principalId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: webApp.identity.principalId
    principalType: 'ServicePrincipal'
    scope: resourceId('Microsoft.Storage/storageAccounts', storageAccountName)
  }
  dependsOn: [ assignIdentity ]
}

output webAppDefaultHostName string = webApp.properties.defaultHostName
output webAppResourceId string = webApp.id
