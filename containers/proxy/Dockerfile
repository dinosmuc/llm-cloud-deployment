FROM python:3.14-slim

WORKDIR /proxy

COPY ./requirements.txt /proxy/requirements.txt

RUN pip install --no-cache-dir --upgrade -r /proxy/requirements.txt

COPY ./main.py /proxy/main.py

EXPOSE 80

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "80"]
