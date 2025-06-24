@description('Nome do recurso Translator')
param translatorName string = 'translator'

resource translator 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: translatorName
  location: resourceGroup().location
  kind: 'Translator'
  sku: {
    name: 'F0' // Free tier, muda se quiseres um pago
  }
  properties: {
    apiProperties: {}
  }
}

output translatorEndpoint string = translator.properties.endpoint
output translatorKey string = listKeys(translator.id, '2023-05-01').keys[0].value
