targetScope = 'resourceGroup'

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
@description('SAS token para o container “reddit-posts” sem "?" inicial')
param containerSasToken string

resource existingPlan 'Microsoft.Web/serverfarms@2022-03-01' existing = {
  name: planName
}

resource webApp 'Microsoft.Web/sites@2022-03-01' = {
  name: webAppName
  location: location
  kind: 'app,linux'
  properties: {
    serverFarmId: existingPlan.id
    siteConfig: {
      linuxFxVersion: 'DOCKER|' + imageName
      alwaysOn: true
      appSettings: [
        if (!empty(containerRegistryUrl) && !empty(containerRegistryUsername) && !empty(containerRegistryPassword)) {
          {
            name: 'DOCKER_REGISTRY_SERVER_URL'
            value: containerRegistryUrl
          }
        }
        if (!empty(containerRegistryUrl) && !empty(containerRegistryUsername) && !empty(containerRegistryPassword)) {
          {
            name: 'DOCKER_REGISTRY_SERVER_USERNAME'
            value: containerRegistryUsername
          }
        }
        if (!empty(containerRegistryUrl) && !empty(containerRegistryUsername) && !empty(containerRegistryPassword)) {
          {
            name: 'DOCKER_REGISTRY_SERVER_PASSWORD'
            value: containerRegistryPassword
          }
        }
        {
          name: 'CONTAINER_SAS_TOKEN'
          value: containerSasToken
        }
        // Se precisares da URL completa:
        // {
        //   name: 'CONTAINER_URL_WITH_SAS'
        //   value: 'https://' + 'miniprojetostorage20.blob.core.windows.net' + '/reddit-posts?' + containerSasToken
        // }
      ]
    }
  }
  dependsOn: [
    existingPlan
  ]
}

output webAppDefaultHostName string = webApp.properties.defaultHostName
output webAppResourceId string = webApp.id
