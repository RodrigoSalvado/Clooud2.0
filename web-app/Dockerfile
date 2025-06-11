# Usa imagem oficial Python 3.10
FROM --platform=linux/amd64 python:3.10-slim

# Define diretório de trabalho
WORKDIR /app

# Copia ficheiro de dependências e instala
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Copia o resto do código
COPY . .

# Expõe a porta do Flask
EXPOSE 5000

# Define variáveis de ambiente para o Flask
ENV FLASK_APP=app.py
ENV FLASK_RUN_HOST=0.0.0.0

# Arranca a aplicação
CMD ["flask", "run", "--host=0.0.0.0"]
