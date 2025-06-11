// como usar
// az deployment sub create \
//   --location <região> \
//   --template-file main.bicep \
//   --parameters rgName=MiniProjetoCloud2.0 location=weasteurope


param location string = resourceGroup().location
param rgName string = 'MiniProjetoCloud2.0'

resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: rgName
  location: location
}

