@description('Nome do recurso Translator')
param translatorName string = 'translator'

resource translator 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: translatorName
  location: resourceGroup().location
  kind: 'Translator'
  sku: {
    name: 'F0'
  }
  properties: {}
}
