@description('Nome do Resource Group a criar')
param rgName string

@description('Localização do Resource Group')
param location string = resourceGroup().location

resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: rgName
  location: location
}
