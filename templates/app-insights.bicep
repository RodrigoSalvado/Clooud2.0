@description('Nome do Application Insights a criar.')
param appInsightsName string

@description('Localização do Application Insights. Defaults para a localização do resource group.')
param location string = resourceGroup().location

@description('Tags a aplicar no Application Insights (opcional).')
param tags object = {}

resource appInsights 'microsoft.insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
  }
}

output appInsightsResourceId string = appInsights.id
output instrumentationKey string = appInsights.properties.InstrumentationKey
