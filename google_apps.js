function doPost(e) {
  var ss = SpreadsheetApp.openById(
    "1WeLe9zO71zoKhkdj2usptbRQC0Gy6PT6_3CibpJ6gEU"
  ); // Reemplaza con el ID de tu hoja de cálculo
  var sheet = ss.getSheetByName("Sheet1"); // Cambia "Hoja1" por el nombre de tu hoja si es diferente

  var data;
  try {
    data = JSON.parse(e.postData.contents).data;
  } catch (error) {
    return ContentService.createTextOutput(
      "Error parsing JSON data: " + error
    ).setMimeType(ContentService.MimeType.TEXT);
  }

  var rows = data.map(function (entry) {
    return [
      entry.timestamp,
      entry.temperature,
      entry.humidity,
      entry.light,
      entry.deviceID,
      entry.region,
      entry.location,
    ];
  });

  // Escribir los datos en la siguiente fila disponible
  if (rows.length > 0) {
    sheet
      .getRange(sheet.getLastRow() + 1, 1, rows.length, rows[0].length)
      .setValues(rows);
  }

  return ContentService.createTextOutput("Success").setMimeType(
    ContentService.MimeType.TEXT
  );
}

function doGet(e) {
  return ContentService.createTextOutput(
    "This script only accepts POST requests."
  ).setMimeType(ContentService.MimeType.TEXT);
}
