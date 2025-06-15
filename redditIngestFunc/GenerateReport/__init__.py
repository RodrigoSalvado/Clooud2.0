import logging
import azure.functions as func
import os
import json
import requests
import pandas as pd
from datetime import datetime
from azure.storage.blob import BlobClient, ContentSettings
from io import BytesIO

# (Opcional se gerar gráficos:)
import matplotlib.pyplot as plt
from scipy.stats import gaussian_kde
from wordcloud import WordCloud, STOPWORDS
# E se usar transformers dentro da Function, import e inicialização aqui.
# Atenção: isso pode aumentar cold start. Avalie se realmente vai gerar sentimento nesta Function ou se já foi feito no Flask.

logger = logging.getLogger(__name__)

def main(req: func.HttpRequest) -> func.HttpResponse:
    logger.info("GenerateReport: recebendo requisição")
    try:
        body = req.get_json()
    except ValueError:
        return func.HttpResponse("JSON inválido no body", status_code=400)

    post_ids = body.get("post_ids")
    if not isinstance(post_ids, list) or not post_ids:
        return func.HttpResponse("Campo 'post_ids' ausente ou não é lista não-vazia", status_code=400)

    # Obter URL da Function ou endpoint para buscar posts completos
    GET_POSTS_FUNCTION_URL = os.getenv("GET_POSTS_FUNCTION_URL")
    if not GET_POSTS_FUNCTION_URL:
        msg = "GET_POSTS_FUNCTION_URL não configurado nas configurações da Function"
        logger.error(msg)
        return func.HttpResponse(msg, status_code=500)

    # 1) Buscar dados completos do Cosmos via Function GET_POSTS
    try:
        # Exemplo: GET com query param ids=...
        ids_param = ",".join(post_ids)
        resp = requests.get(GET_POSTS_FUNCTION_URL, params={"ids": ids_param}, timeout=30)
        resp.raise_for_status()
        data = resp.json()
        # Extrair posts: caso a Function retorne {"posts": [...]}, ou lista diretamente
        if isinstance(data, dict) and "posts" in data and isinstance(data["posts"], list):
            posts = data["posts"]
        elif isinstance(data, list):
            posts = data
        else:
            logger.warning(f"GET_POSTS retornou JSON inesperado: {data!r}; assumindo lista vazia")
            posts = []
    except Exception as e:
        logger.error(f"Erro ao chamar GET_POSTS_FUNCTION_URL: {e}", exc_info=True)
        return func.HttpResponse(f"Erro ao buscar posts: {e}", status_code=500)

    if not posts:
        # Se quiser, pode retornar 204 ou 200 com mensagem
        logger.warning("Nenhum post retornado para os IDs fornecidos")
        # Ainda assim criar CSV vazio
    # 2) Montar DataFrame e CSV em memória
    try:
        df = pd.DataFrame(posts)
    except Exception as e:
        logger.error(f"Erro ao montar DataFrame: {e}", exc_info=True)
        return func.HttpResponse(f"Erro interno ao montar relatório: {e}", status_code=500)

    csv_buffer = BytesIO()
    try:
        df.to_csv(csv_buffer, index=False, encoding="utf-8")
        csv_buffer.seek(0)
    except Exception as e:
        logger.error(f"Erro ao gerar CSV em memória: {e}", exc_info=True)
        return func.HttpResponse(f"Erro ao gerar CSV: {e}", status_code=500)

    # 3) Fazer upload para Blob Storage via SAS
    CONTAINER_ENDPOINT_SAS = os.getenv("CONTAINER_ENDPOINT_SAS")
    if not CONTAINER_ENDPOINT_SAS:
        msg = "CONTAINER_ENDPOINT_SAS não configurado"
        logger.error(msg)
        return func.HttpResponse(msg, status_code=500)

    # Dividir base e token
    try:
        parts = CONTAINER_ENDPOINT_SAS.split('?', 1)
        if len(parts) != 2:
            raise ValueError("Formato inválido de CONTAINER_ENDPOINT_SAS")
        sas_url_base, sas_token = parts
    except Exception as e:
        logger.error(f"Formato inválido de CONTAINER_ENDPOINT_SAS: {e}", exc_info=True)
        return func.HttpResponse(f"Erro na configuração de Blob SAS: {e}", status_code=500)

    # Definir nome único para o blob
    timestamp = datetime.utcnow().strftime('%Y%m%d_%H%M%S')
    blob_name = f"relatorio_{timestamp}.csv"
    blob_url = f"{sas_url_base}/{blob_name}?{sas_token}"

    try:
        # Upload do CSV
        blob_client = BlobClient.from_blob_url(blob_url)
        # Use upload_blob aceitando stream
        blob_client.upload_blob(csv_buffer.getvalue(), overwrite=True, content_settings=ContentSettings(
            content_type="text/csv",
            content_disposition="inline"
        ))
    except Exception as e:
        logger.error(f"Erro ao fazer upload do CSV: {e}", exc_info=True)
        return func.HttpResponse(f"Erro ao enviar CSV ao Blob: {e}", status_code=500)

    uploaded = {"csv_blob_url": blob_url}

    # 4) (Opcional) gerar gráficos e fazer upload também
    # Se desejar gerar gráficos (KDE, WordCloud), inclua aqui.
    # Atenção: as bibliotecas devem estar presentes e o ambiente suportar matplotlib em headless.
    # Exemplo rápido de geração de gráfico de densidade baseado em confiança, caso seu posts já contenham campo 'scores_raw' ou confianças:
    try:
        # Verificar se cada post tem confiança numérica em post['probabilidade'] ou em scores_raw
        # Aqui, como exemplo, buscamos post.get('probabilidade') se existir:
        confidences = []
        for post in posts:
            p = post.get('probabilidade')
            if isinstance(p, (int, float)):
                confidences.append(float(p))
        if len(confidences) > 1:
            # Gera KDE simples
            x = np.linspace(0, 100, 500)
            kde = gaussian_kde(confidences)
            y = kde(x)
            # Normaliza para percentuais relativos
            y = y / y.sum() * 100
            plt.figure(figsize=(8, 4))
            plt.plot(x, y, label="Confiança")
            plt.fill_between(x, y, alpha=0.2)
            plt.xlabel("Confiança (%)")
            plt.ylabel("Densidade normalizada (%)")
            plt.title("Distribuição de Confiança")
            plt.legend()
            plt.tight_layout()
            buf = BytesIO()
            plt.savefig(buf, format="png", dpi=200)
            plt.close()
            buf.seek(0)
            # Upload
            graf_name = f"distribuicao_confianca_{timestamp}.png"
            graf_blob_url = f"{sas_url_base}/{graf_name}?{sas_token}"
            blob_client = BlobClient.from_blob_url(graf_blob_url)
            blob_client.upload_blob(buf.getvalue(), overwrite=True, content_settings=ContentSettings(
                content_type="image/png",
                content_disposition="inline"
            ))
            uploaded["grafico_blob_url"] = graf_blob_url
        # WordCloud se houver texto acumulado:
        texts = []
        for post in posts:
            txt = post.get('selftext') or post.get('title') or ""
            if txt:
                texts.append(txt)
        full_text = " ".join(texts)
        words = re.findall(r"\w+", full_text)
        filtered = [w for w in words if w.lower() not in STOPWORDS]
        if filtered:
            wc = WordCloud(width=700, height=350, background_color="white", stopwords=set(STOPWORDS)).generate(" ".join(filtered))
            plt.figure(figsize=(7, 3.5))
            plt.imshow(wc, interpolation="bilinear")
            plt.axis("off")
            plt.tight_layout()
            buf2 = BytesIO()
            plt.savefig(buf2, format="png", dpi=200)
            plt.close()
            buf2.seek(0)
            wc_name = f"nuvem_palavras_{timestamp}.png"
            wc_blob_url = f"{sas_url_base}/{wc_name}?{sas_token}"
            blob_client = BlobClient.from_blob_url(wc_blob_url)
            blob_client.upload_blob(buf2.getvalue(), overwrite=True, content_settings=ContentSettings(
                content_type="image/png",
                content_disposition="inline"
            ))
            uploaded["wordcloud_blob_url"] = wc_blob_url
    except Exception as e:
        # Apenas log, não falha toda a Function:
        logger.warning(f"Falha ao gerar/upload de gráficos: {e}", exc_info=True)

    # 5) Retornar JSON com URLs dos blobs
    return func.HttpResponse(
        json.dumps({
            "status": "success",
            "uploaded": uploaded
        }),
        status_code=200,
        mimetype="application/json"
    )
