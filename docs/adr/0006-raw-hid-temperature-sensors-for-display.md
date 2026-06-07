# ADR 0006: Raw HID Temperature Sensors for Display

Apple Silicon does not expose stable public APIs for named CPU/GPU/SoC temperature channels, while the machine does expose raw `AppleARMPMUTempSensor` values through HID event services. We use these raw HID temperature readings for user-visible monitoring and highest-hotspot display, but we do not map private raw names to CPU/GPU/SoC control channels unless that mapping is reliable for the detected model; automatic control remains conservative and falls back to Apple default when classified critical sensors are unavailable.
