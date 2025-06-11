import logging
import azure.functions as func

def main(docs: func.DocumentList) -> None:
    if docs:
        logging.info(f"Recebidos {len(docs)} documentos novos/alterados.")
        for doc in docs:
            logging.info(f"Processando documento id={doc.get('id')}: {doc}")
            # Exemplo: chame aqui um serviço de análise de sentimento
            # sentiment = analyze_sentiment(doc.get("text"))
            # depois, talvez grave o resultado de volta no Cosmos ou envie para outro sistema
