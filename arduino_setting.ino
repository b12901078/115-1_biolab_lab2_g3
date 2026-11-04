#include <SoftwareSerial.h>

SoftwareSerial BT(10, 11);

const int EMG_PIN = A0;
const unsigned long SAMPLE_INTERVAL_US = 1000;  // 100 Hz

unsigned long nextSampleTime = 0;

void setup() {
  Serial.begin(115200);
  BT.begin(9600);

  nextSampleTime = micros();

  Serial.println("EMG acquisition started");
}

void loop() {
  unsigned long now = micros();

  if ((long)(now - nextSampleTime) >= 0) {
    nextSampleTime += SAMPLE_INTERVAL_US;

    int emgValue = analogRead(EMG_PIN);

    Serial.println(emgValue);

    //BT.print();
    BT.println(emgValue*2-320);
  }
}
