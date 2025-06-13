@description('Nome do recurso Translator (globalmente único)')
param translatorName string

@description('Localização para o recurso Translator')
param location string = resourceGroup().location

// SKU Free para Translator é F0
var skuName = 'F0'

resource translator 'Microsoft.CognitiveServices/accounts@2021-10-01' = {
  name: translatorName
  location: location
  kind: 'Translator'
  sku: {
    name: skuName
  }
  properties: {
    // não há propriedades obrigatórias adicionais para Translator free
    // porém, se desejar, pode configurar customDomain, encryption, etc.
  }
}

// Opcionalmente, exportar endpoint e chave
output translatorEndpoint string = translator.properties.endpoint
// Atenção: expor chaves em outputs pode vazar secrets. Por segurança, não expor chaves como output.
// Você pode obter chaves via Azure CLI ou SDK após a implantação.
