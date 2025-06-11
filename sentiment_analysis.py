import os
import numpy as np
import matplotlib.pyplot as plt
import pandas as pd
from scipy.stats import gaussian_kde
from transformers import pipeline
from azure.storage.blob import BlobServiceClient
from wordcloud import WordCloud, STOPWORDS

# 1. Lista de frases a avaliar
sentences = [
    "Never thought I'd find myself agreeing so hard with Nancy Pelosi",
    "Using AI Feels Like Dipping Your Hand in the Pool of Human Consciousness",
    "Just caught the Falcon 9 launch from a Tesla Uber",
    "Elon Musk calls for the United States and Europe to establish a \"zero-tariff\" system and a \"free trade zone.\"",
    "Full remarks by Elon Musk at 'The League Congress' hosted by Italian Deputy Prime Minister Matteo Salvini",
    "Elon in video: \"A country is not its geography. A country is its people. This is a fundamental concept that is truly obvious.\"",
    "Isn’t that interesting. Elon is such a terrible person right?",
    "DOGE’s Antonio Gracias Says Massive Numbers of Illegal Migrants Who Received SSN’s Are on Taxpayer Funded Benefits",
    "Beautiful"
]

# 2. Inicializar pipeline zero-shot
classifier = pipeline("zero-shot-classification", model="facebook/bart-large-mnli")
candidate_labels = ["negative", "neutral", "positive"]

# 3. Recolher probabilidades e resultados
neg_probs, neu_probs, pos_probs = [], [], []
records = []

for sent in sentences:
    res = classifier(sent, candidate_labels)
    # determina top-label e score
    top_label = res["labels"][0].capitalize()
    top_score = int(res["scores"][0] * 100)
    records.append({
        "Review": sent,
        "Sentimento": top_label,
        "Pontuação (%)": top_score
    })
    # dicionário de scores
    sd = dict(zip(res["labels"], res["scores"]))
    neg_probs.append(sd["negative"])
    neu_probs.append(sd["neutral"])
    pos_probs.append(sd["positive"])

# 4. Gerar DataFrame e guardar como imagem de tabela
df = pd.DataFrame(records)
fig, ax = plt.subplots(figsize=(12, len(df)*0.4 + 1))
ax.axis('off')
tbl = ax.table(cellText=df.values, colLabels=df.columns, cellLoc='center', loc='center')
tbl.auto_set_font_size(False)
tbl.set_fontsize(10)
tbl.scale(1, 1.5)
plt.tight_layout()
table_path = "sentiment_table.png"
plt.savefig(table_path, dpi=200)
plt.close()

# 5. Gerar gráfico de densidade
neg_probs = np.array(neg_probs); neu_probs = np.array(neu_probs); pos_probs = np.array(pos_probs)
kde_neg = gaussian_kde(neg_probs); kde_neu = gaussian_kde(neu_probs); kde_pos = gaussian_kde(pos_probs)
x = np.linspace(0, 1, 500)
plt.figure(figsize=(10, 5))
plt.plot(x, kde_neg(x), label='Negative')
plt.plot(x, kde_neu(x), label='Neutral')
plt.plot(x, kde_pos(x), label='Positive')
plt.xlabel('Probabilidade'); plt.ylabel('Densidade')
plt.title('Distribuição de Probabilidades de Sentimento (Zero-Shot)')
plt.legend(); plt.tight_layout()
chart_path = "sentiment_distribution.png"
plt.savefig(chart_path, dpi=200)
plt.close()

# 6. Gerar nuvem de palavras
# junta todos os textos, remove stopwords básicas
text = " ".join(sentences)
stopwords = set(STOPWORDS)
wc = WordCloud(width=800, height=400, background_color="white",
               stopwords=stopwords).generate(text)

plt.figure(figsize=(12, 6))
plt.imshow(wc, interpolation="bilinear")
plt.axis("off")
wordcloud_path = "sentiment_wordcloud.png"
plt.savefig(wordcloud_path, dpi=200)
plt.close()


# 6. Configuração do Azure Blob Storage
conn_str = os.environ.get("DEPLOYMENT_STORAGE_CONNECTION_STRING")
if not conn_str:
    raise ValueError("Define a variável de ambiente DEPLOYMENT_STORAGE_CONNECTION_STRING com a tua connection string do Azure.")

blob_service_client = BlobServiceClient.from_connection_string(conn_str)
container_name = "reddit-posts"
container_client = blob_service_client.get_container_client(container_name)

# 7. Testar acesso: listar blobs existentes
print(f"Blobs atualmente em '{container_name}':")
try:
    for blob in container_client.list_blobs():
        print("  -", blob.name)
except Exception as e:
    print("Erro ao listar blobs:", e)
    raise

# 8. Fazer o upload do gráfico
blob_name = os.path.basename(output_path)
with open(output_path, "rb") as data:
    container_client.upload_blob(name=blob_name, data=data, overwrite=True)

print(f"Gráfico '{blob_name}' enviado com sucesso para o container '{container_name}'.")
