import requests, uuid, json, os

#Configuração
key = os.environ.get("TANSLATOR_KEY")
endpoint = os.environ.get("TRNASLATOR_ENDPOINT")
location = "francecentral"

#Função para detectar idioma
def detect_language(text):
    path = '/detect'
    url = endpoint + path
    params = {'api-version': '3.0'}
    headers = {
        'Ocp-Apim-Subscription-Key': key,
        'Ocp-Apim-Subscription-Region': location,
        'Content-Type': 'application/json',
        'X-ClientTraceId': str(uuid.uuid4())
    }
    body = [{'text': text}]
    resp = requests.post(url, params=params, headers=headers, json=body)
    resp.raise_for_status()
    detection = resp.json()
    # Retorna o código ISO do idioma com maior confiança
    return detection[0]['language']

#Função para traduzir para inglês
def translate_to_english(text, from_lang=None):
    path = '/translate'
    url = endpoint + path
    params = {
        'api-version': '3.0',
        # Se já sabemos o idioma, podemos passá-lo; senão, basta omitir 'from' e o serviço auto-detecta
        **({'from': from_lang} if from_lang else {}),
        'to': ['en']
    }
    headers = {
        'Ocp-Apim-Subscription-Key': key,
        'Ocp-Apim-Subscription-Region': location,
        'Content-Type': 'application/json',
        'X-ClientTraceId': str(uuid.uuid4())
    }
    body = [{'text': text}]
    resp = requests.post(url, params=params, headers=headers, json=body)
    resp.raise_for_status()
    return resp.json()

if name == 'main':
    texto_original = 'I would really like to drive your car around the block a few times!'

    # 1) Detecta idioma
    idioma = detect_language(texto-original)
    print(f"Idioma detectado: {idioma}")

    # 2) Traduz para inglês
    resultado = translate_to_english(texto_original, from_lang=idioma)
    print(json.dumps(resultado, ensure_ascii=False, indent=4))