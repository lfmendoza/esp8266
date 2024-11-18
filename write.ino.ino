#include <Wire.h>
#include <Adafruit_AHTX0.h>
#include <ESP8266WiFi.h>
#include <WiFiClientSecure.h>
#include <ESP8266HTTPClient.h>
#include <time.h>
#include <ArduinoJson.h>

// Configuración WiFi
const char* ssid = "Reemplaza con tu SSID";             // Reemplaza con tu SSID
const char* password = "Reemplaza con tu contraseña";      // Reemplaza con tu contraseña

// URL del script de Google Apps
const char* googleScriptUrl = "https://script.google.com/macros/s/AKfycbxHfsSHlAMt7WjfLJxWF_xrP2QXHHta2L8dAfVULmsWU8M7tXxCPkLJBOUVQE2wWq34/exec"; // Reemplaza "YOUR_SCRIPT_ID" con el ID de tu script

// Configuración del sensor AHT10
Adafruit_AHTX0 aht;
bool sensorInicializado = false;

// Definición de regiones oficiales de Guatemala con rangos realistas
struct Region {
  const char* name;
  float tempMin, tempMax;
  float humidityMin, humidityMax;
  float lightMin, lightMax;
  const char* locations[5];
};

// Lista de regiones con datos realistas
Region regions[] = {
  {"Región Metropolitana", 15.0, 28.0, 60.0, 80.0, 50.0, 70.0, {"Zona_1", "Zona_2", "Zona_3", "Zona_4", "Zona_5"}},
  {"Región Norte", 22.0, 32.0, 70.0, 90.0, 60.0, 80.0, {"Cobán", "Chisec", "Raxruhá", "Fray", "Chahal"}},
  {"Región Nororiente", 24.0, 35.0, 50.0, 70.0, 70.0, 100.0, {"Zacapa", "Chiquimula", "Esquipulas", "Gualán", "La Unión"}},
  {"Región Suroriente", 20.0, 34.0, 55.0, 75.0, 70.0, 90.0, {"Jalapa", "Jutiapa", "Santa Rosa", "Cuilapa", "Barberena"}},
  {"Región Central", 18.0, 28.0, 65.0, 85.0, 50.0, 70.0, {"Chimaltenango", "Sacatepéquez", "Escuintla", "Antigua", "Panajachel"}},
  {"Región Suroccidente", 15.0, 25.0, 70.0, 90.0, 40.0, 60.0, {"Quetzaltenango", "Retalhuleu", "San Marcos", "Totonicapán", "Sololá"}},
  {"Región Noroccidente", 10.0, 22.0, 75.0, 95.0, 30.0, 50.0, {"Huehuetenango", "Quiché", "Chajul", "Nebaj", "Ixcán"}},
  {"Región Petén", 23.0, 33.0, 80.0, 100.0, 60.0, 85.0, {"Flores", "Sayaxché", "La Libertad", "San Benito", "Melchor"}}
};

const int numRegions = sizeof(regions) / sizeof(regions[0]);
const int numDevices = 1000;    // Número total de dispositivos simulados
const int batchSize = 10;       // Tamaño de cada lote reducido para evitar problemas de memoria

// Función para conectar al WiFi
void connectToWiFi() {
  WiFi.begin(ssid, password);
  Serial.println("Conectando a WiFi...");
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println("\nConexión establecida.");
  Serial.print("IP: ");
  Serial.println(WiFi.localIP());
}

// Función para generar ID de dispositivo como hash hexadecimal
String generateDeviceID(int regionIndex, int locationIndex) {
  char id[15];
  sprintf(id, "%02X%02X", regionIndex, locationIndex);
  for (int i = 0; i < 4; i++) {
    sprintf(id + strlen(id), "%02X", random(0, 256));
  }
  return String(id);
}

// Función para generar un número flotante aleatorio entre min y max
float randomFloat(float min, float max) {
  return min + (max - min) * random(0, 10000) / 10000.0;
}

void setup() {
  Serial.begin(115200);
  Wire.begin(D2, D1); // SDA = D2 (GPIO 4), SCL = D1 (GPIO 5)

  connectToWiFi();

  // Inicializar el sensor AHT10
  Serial.println("Inicializando sensor AHT10...");
  sensorInicializado = aht.begin();
  if (sensorInicializado) {
    Serial.println("Sensor AHT10 inicializado.");
  } else {
    Serial.println("Error al inicializar el sensor AHT10");
    // Continuar sin el sensor si es necesario
  }

  // Configurar tiempo (para timestamp)
  configTime(-6 * 3600, 0, "pool.ntp.org", "time.nist.gov"); // UTC-6 para Guatemala
  while (time(nullptr) < 100000) {
    delay(100);
  }
}

void loop() {
  time_t now = time(nullptr);
  struct tm* timeinfo = localtime(&now);
  char timestamp[30];
  strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", timeinfo);

  for (int batchStart = 0; batchStart < numDevices; batchStart += batchSize) {
    // Definir capacidad del JSON según el tamaño del lote reducido
    StaticJsonDocument<2000> doc;

    JsonArray data = doc.createNestedArray("data");

    for (int i = batchStart; i < batchStart + batchSize && i < numDevices; i++) {
      int regionIndex = i % numRegions;
      int locationIndex = random(0, 5);

      Region region = regions[regionIndex];
      float temp;
      float humidity;
      float light;

      if (sensorInicializado) {
        // Leer datos reales del sensor
        sensors_event_t humidityEvent, tempEvent;
        aht.getEvent(&humidityEvent, &tempEvent);
        temp = tempEvent.temperature;
        humidity = humidityEvent.relative_humidity;
      } else {
        // Generar datos simulados
        temp = randomFloat(region.tempMin, region.tempMax);
        humidity = randomFloat(region.humidityMin, region.humidityMax);
      }

      // Simular datos de luz
      light = randomFloat(region.lightMin, region.lightMax);

      String deviceID = generateDeviceID(regionIndex, locationIndex);

      JsonObject entry = data.createNestedObject();
      entry["timestamp"] = timestamp;
      entry["temperature"] = temp;
      entry["humidity"] = humidity;
      entry["light"] = light;
      entry["deviceID"] = deviceID;
      entry["region"] = region.name;
      entry["location"] = region.locations[locationIndex];
    }

    // Serializar JSON a cadena
    String jsonData;
    serializeJson(doc, jsonData);

    // Enviar datos del lote
    sendBatchData(jsonData);

    // Pequeño retraso para evitar saturar el ESP8266
    delay(100);
  }

  // Esperar antes de la siguiente iteración
  delay(60000); // 1 minuto
}

// Función para enviar datos del lote
void sendBatchData(String& jsonData) {
  if (WiFi.status() == WL_CONNECTED) {
    WiFiClientSecure client;
    client.setInsecure();

    HTTPClient http;
    http.setTimeout(20000);

    http.begin(client, googleScriptUrl);
    http.addHeader("Content-Type", "application/json");

    int httpCode = http.POST(jsonData);

    if (httpCode > 0) {
      if (httpCode >= 300 && httpCode < 400) {
        // Manejo de redirección
        String newUrl = http.header("Location");
        if (newUrl.length() > 0) {
          Serial.println("Redirigido a: " + newUrl);
          http.end();

          http.begin(client, newUrl);
          http.addHeader("Content-Type", "application/json");
          httpCode = http.POST(jsonData);
        } else {
          Serial.println("Error: Redirección sin encabezado 'Location'");
          String payload = http.getString();
          Serial.println("Respuesta del servidor: " + payload);
        }
      }

      if (httpCode == HTTP_CODE_OK) {
        String payload = http.getString();
        Serial.println("Respuesta: " + payload);
      } else {
        String payload = http.getString();
        Serial.println("Error al enviar datos: " + String(httpCode) + " - " + http.errorToString(httpCode));
        Serial.println("Respuesta del servidor: " + payload);
      }
    } else {
      Serial.println("Error al enviar datos: " + String(httpCode) + " - " + http.errorToString(httpCode));
    }

    http.end();
  } else {
    Serial.println("WiFi desconectado.");
    connectToWiFi();
  }
}

