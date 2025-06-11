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

@minLength(1)
@maxLength(40)
@description('Nome da Storage Account usada no Private Endpoint, ex.: "miniprojetostorage20". Necessário se quiser montar URL completa ou usar Managed Identity.')
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

// Referenciar App Service Plan existente
resource existingPlan 'Microsoft.Web/serverfarms@2022-03-01' existing = {
  name: planName
}

// Cria ou atualiza o Web App
resource webApp 'Microsoft.Web/sites@2022-03-01' = {
  name: webAppName
  location: location
  kind: 'app,linux'
  properties: {
    serverFarmId: existingPlan.id
    siteConfig: {
      linuxFxVersion: 'DOCKER|${imageName}'
      alwaysOn: true
      appSettings: [
        // Docker registry privado, se necessário
        if (containerRegistryUrl != '' && containerRegistryUsername != '' && containerRegistryPassword != '') {
          {
            name: 'DOCKER_REGISTRY_SERVER_URL'
            value: containerRegistryUrl
          }
        }
        if (containerRegistryUrl != '' && containerRegistryUsername != '' && containerRegistryPassword != '') {
          {
            name: 'DOCKER_REGISTRY_SERVER_USERNAME'
            value: containerRegistryUsername
          }
        }
        if (containerRegistryUrl != '' && containerRegistryUsername != '' && containerRegistryPassword != '') {
          {
            name: 'DOCKER_REGISTRY_SERVER_PASSWORD'
            value: containerRegistryPassword
          }
        }
        // Porta do Flask
        {
          name: 'WEBSITES_PORT'
          value: '5000'
        }
        // SAS token, se estiver a usar SAS
        if (containerSasToken != '') {
          {
            name: 'CONTAINER_SAS_TOKEN'
            value: containerSasToken
          }
        }
        // URL completa do container com SAS (se for o caso e containerSasToken fornecido)
        if (containerSasToken != '') {
          {
            name: 'CONTAINER_URL_WITH_SAS'
            value: 'https://${storageAccountName}.blob.core.windows.net/${containerName}?${containerSasToken}'
          }
        }
        // Se quiseres usar Managed Identity em vez de SAS, podes definir uma App Setting que informe o código para usar AD.
        // Por exemplo:
        // {
        //   name: 'USE_MANAGED_IDENTITY'
        //   value: 'true'
        // }
        // E no código Flask, usa DefaultAzureCredential para aceder à Storage via Private Endpoint.
      ]
    }
  }
  dependsOn: [
    existingPlan
  ]
}

// 2. VNet Integration (Regional) para que o Web App possa aceder ao Storage via Private Endpoint
//    A subnet especificada deve estar livre para VNet Integration (sem delegação de outro serviço).
resource vnetIntegration 'Microsoft.Web/sites/virtualNetworkConnections@2021-03-01' = {
  name: '${webApp.name}/${subnetName}'
  properties: {
    subnetResourceId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetName)
  }
  dependsOn: [
    webApp
  ]
}

// 3. (Opcional) Habilitar Managed Identity no Web App para aceder ao Storage sem SAS
resource webAppIdentity 'Microsoft.Web/sites@2022-03-01' existing = {
  name: webAppName
}
resource updateIdentity 'Microsoft.Web/sites@2022-03-01' = if (true) {
  name: webAppName
  properties: {
    identity: {
      type: 'SystemAssigned'
    }
  }
  dependsOn: [
    webApp
  ]
}

// Nota: Para usar Managed Identity, deves atribuir à identidade gerida do Web App a role "Storage Blob Data Contributor"
// no âmbito da Storage Account. Isso pode ser feito num outro passo (CLI) ou manualmente no portal, ou via Bicep:
// Por exemplo:
// resource roleAssignment 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = {
//   name: guid(storageAccount.id, 'StorageBlobDataContributor', webApp.identity.principalId)
//   properties: {
//     roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe') // Storage Blob Data Contributor
//     principalId: webApp.identity.principalId
//     principalType: 'ServicePrincipal'
//     scope: storageAccount.id
//   }
//   dependsOn: [
//     updateIdentity
//   ]
// }

// Outputs
output webAppDefaultHostName string = webApp.properties.defaultHostName
output webAppResourceId string = webApp.id
