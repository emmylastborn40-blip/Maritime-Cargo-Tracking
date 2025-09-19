;; container-iot-integration.clar
;; Container IoT Integration Smart Contract
;; Manages IoT sensor data ingestion, validation, and real-time container monitoring
;; Handles environmental tracking, GPS location updates, and alert systems

;; Constants and Error Codes
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_NOT_FOUND (err u101))
(define-constant ERR_INVALID_DATA (err u102))
(define-constant ERR_SENSOR_OFFLINE (err u103))
(define-constant ERR_THRESHOLD_VIOLATION (err u104))
(define-constant ERR_DEVICE_NOT_REGISTERED (err u105))
(define-constant ERR_DUPLICATE_REGISTRATION (err u106))
(define-constant ERR_INVALID_TIMESTAMP (err u107))
(define-constant ERR_CALIBRATION_REQUIRED (err u108))
(define-constant ERR_BATTERY_LOW (err u109))
(define-constant ERR_COMMUNICATION_TIMEOUT (err u110))

;; Environmental thresholds and limits
(define-constant MIN_TEMPERATURE -4000) ;; -40.00C in hundredths
(define-constant MAX_TEMPERATURE 8500)  ;; 85.00C in hundredths
(define-constant MIN_HUMIDITY u0)       ;; 0% relative humidity
(define-constant MAX_HUMIDITY u10000)   ;; 100.00% relative humidity in hundredths
(define-constant MAX_SHOCK_THRESHOLD u500) ;; Maximum acceptable shock in G-force hundredths
(define-constant MIN_BATTERY_LEVEL u1000)  ;; 10.00% minimum battery level
(define-constant DATA_RETENTION_BLOCKS u52560) ;; ~1 year of data retention

;; IoT device and sensor data structures
(define-map iot-devices
    { device-id: (string-ascii 64) }
    {
        container-id: (string-ascii 32),
        owner: principal,
        device-type: (string-ascii 50),
        installation-date: uint,
        last-communication: uint,
        battery-level: uint,
        is-active: bool,
        firmware-version: (string-ascii 20),
        calibration-status: (string-ascii 20),
        location-lat: int,
        location-lon: int
    }
)

(define-map environmental-data
    { device-id: (string-ascii 64), timestamp: uint }
    {
        temperature: int,
        humidity: uint,
        atmospheric-pressure: uint,
        light-exposure: uint,
        vibration-level: uint,
        shock-detection: uint,
        door-status: bool,
        data-hash: (buff 32)
    }
)

(define-map location-tracking
    { device-id: (string-ascii 64), timestamp: uint }
    {
        latitude: int,
        longitude: int,
        altitude: int,
        speed: uint,
        heading: uint,
        gps-accuracy: uint,
        satellite-count: uint
    }
)

(define-map alert-thresholds
    { device-id: (string-ascii 64) }
    {
        min-temperature: int,
        max-temperature: int,
        max-humidity: uint,
        max-shock: uint,
        max-vibration: uint,
        geofence-enabled: bool,
        geofence-lat: int,
        geofence-lon: int,
        geofence-radius: uint
    }
)

(define-map device-alerts
    { device-id: (string-ascii 64), alert-id: uint }
    {
        alert-type: (string-ascii 50),
        alert-message: (string-ascii 200),
        triggered-at: uint,
        severity-level: uint,
        is-resolved: bool,
        resolved-at: uint,
        current-value: int,
        threshold-value: int
    }
)

(define-map device-maintenance
    { device-id: (string-ascii 64) }
    {
        last-calibration: uint,
        next-calibration: uint,
        maintenance-history: (list 10 uint),
        total-uptime: uint,
        data-transmission-count: uint,
        error-count: uint
    }
)

;; Global counters and statistics
(define-data-var total-devices uint u0)
(define-data-var active-devices uint u0)
(define-data-var total-alerts uint u0)
(define-data-var next-alert-id uint u1)
(define-data-var total-data-points uint u0)

;; Private helper functions
(define-private (validate-environmental-data (temp int) (humidity uint) (pressure uint))
    (and
        (>= temp MIN_TEMPERATURE)
        (<= temp MAX_TEMPERATURE)
        (>= humidity MIN_HUMIDITY)
        (<= humidity MAX_HUMIDITY)
        (> pressure u0)
    )
)

(define-private (check-alert-conditions (device-id (string-ascii 64)) (temp int) (humidity uint) (shock uint))
    (let (
        (thresholds (map-get? alert-thresholds {device-id: device-id}))
    )
        (match thresholds
            threshold-data
                (or
                    (< temp (get min-temperature threshold-data))
                    (> temp (get max-temperature threshold-data))
                    (> humidity (get max-humidity threshold-data))
                    (> shock (get max-shock threshold-data))
                )
            false
        )
    )
)

(define-private (update-device-communication (device-id (string-ascii 64)))
    (match (map-get? iot-devices {device-id: device-id})
        device
            (map-set iot-devices
                {device-id: device-id}
                (merge device {last-communication: stacks-block-height})
            )
        false
    )
)

(define-private (create-alert (device-id (string-ascii 64)) (alert-type (string-ascii 50)) (message (string-ascii 200)) (severity uint) (current-val int) (threshold-val int))
    (let (
        (alert-id (var-get next-alert-id))
    )
        (map-set device-alerts
            {device-id: device-id, alert-id: alert-id}
            {
                alert-type: alert-type,
                alert-message: message,
                triggered-at: stacks-block-height,
                severity-level: severity,
                is-resolved: false,
                resolved-at: u0,
                current-value: current-val,
                threshold-value: threshold-val
            }
        )
        (var-set next-alert-id (+ alert-id u1))
        (var-set total-alerts (+ (var-get total-alerts) u1))
        alert-id
    )
)

;; Public functions for device management
(define-public (register-iot-device
    (device-id (string-ascii 64))
    (container-id (string-ascii 32))
    (device-type (string-ascii 50))
    (firmware-version (string-ascii 20))
    (initial-lat int)
    (initial-lon int)
)
    (let (
        (existing-device (map-get? iot-devices {device-id: device-id}))
    )
        (asserts! (is-none existing-device) ERR_DUPLICATE_REGISTRATION)
        (asserts! (> (len device-id) u0) ERR_INVALID_DATA)
        (asserts! (> (len container-id) u0) ERR_INVALID_DATA)
        
        (map-set iot-devices
            {device-id: device-id}
            {
                container-id: container-id,
                owner: tx-sender,
                device-type: device-type,
                installation-date: stacks-block-height,
                last-communication: stacks-block-height,
                battery-level: u10000, ;; Start at 100%
                is-active: true,
                firmware-version: firmware-version,
                calibration-status: "pending",
                location-lat: initial-lat,
                location-lon: initial-lon
            }
        )
        
        ;; Set default alert thresholds
        (map-set alert-thresholds
            {device-id: device-id}
            {
                min-temperature: 0,     ;; 0C
                max-temperature: 2500,  ;; 25C
                max-humidity: u8000,    ;; 80%
                max-shock: u200,        ;; 2G
                max-vibration: u100,    ;; 1G
                geofence-enabled: false,
                geofence-lat: 0,
                geofence-lon: 0,
                geofence-radius: u0
            }
        )
        
        ;; Initialize maintenance record
        (map-set device-maintenance
            {device-id: device-id}
            {
                last-calibration: u0,
                next-calibration: (+ stacks-block-height u1440), ;; ~10 days
                maintenance-history: (list),
                total-uptime: u0,
                data-transmission-count: u0,
                error-count: u0
            }
        )
        
        (var-set total-devices (+ (var-get total-devices) u1))
        (var-set active-devices (+ (var-get active-devices) u1))
        
        (ok device-id)
    )
)

;; Record environmental sensor data
(define-public (record-environmental-data
    (device-id (string-ascii 64))
    (temperature int)
    (humidity uint)
    (pressure uint)
    (light uint)
    (vibration uint)
    (shock uint)
    (door-open bool)
    (data-hash (buff 32))
)
    (let (
        (device-info (map-get? iot-devices {device-id: device-id}))
        (timestamp stacks-block-height)
    )
        (asserts! (is-some device-info) ERR_DEVICE_NOT_REGISTERED)
        (asserts! (validate-environmental-data temperature humidity pressure) ERR_INVALID_DATA)
        
        (match device-info
            device
                (begin
                    (asserts! (get is-active device) ERR_SENSOR_OFFLINE)
                    (asserts! (is-eq tx-sender (get owner device)) ERR_UNAUTHORIZED)
                    
                    ;; Record the environmental data
                    (map-set environmental-data
                        {device-id: device-id, timestamp: timestamp}
                        {
                            temperature: temperature,
                            humidity: humidity,
                            atmospheric-pressure: pressure,
                            light-exposure: light,
                            vibration-level: vibration,
                            shock-detection: shock,
                            door-status: door-open,
                            data-hash: data-hash
                        }
                    )
                    
                    ;; Update device communication timestamp
                    (update-device-communication device-id)
                    
                    ;; Check for alert conditions
                    (if (check-alert-conditions device-id temperature humidity shock)
                        (let (
                            (alert-id (create-alert 
                                device-id 
                                "environmental" 
                                "Environmental threshold exceeded" 
                                u2 
                                temperature 
                                2500
                            ))
                        )
                            (var-set total-data-points (+ (var-get total-data-points) u1))
                            (ok alert-id)
                        )
                        (begin
                            (var-set total-data-points (+ (var-get total-data-points) u1))
                            (ok u0)
                        )
                    )
                )
            ERR_DEVICE_NOT_REGISTERED
        )
    )
)

;; Update GPS location data
(define-public (update-location
    (device-id (string-ascii 64))
    (latitude int)
    (longitude int)
    (altitude int)
    (speed uint)
    (heading uint)
    (accuracy uint)
    (satellites uint)
)
    (let (
        (device-info (map-get? iot-devices {device-id: device-id}))
        (timestamp stacks-block-height)
    )
        (asserts! (is-some device-info) ERR_DEVICE_NOT_REGISTERED)
        
        (match device-info
            device
                (begin
                    (asserts! (get is-active device) ERR_SENSOR_OFFLINE)
                    (asserts! (is-eq tx-sender (get owner device)) ERR_UNAUTHORIZED)
                    
                    ;; Record location data
                    (map-set location-tracking
                        {device-id: device-id, timestamp: timestamp}
                        {
                            latitude: latitude,
                            longitude: longitude,
                            altitude: altitude,
                            speed: speed,
                            heading: heading,
                            gps-accuracy: accuracy,
                            satellite-count: satellites
                        }
                    )
                    
                    ;; Update device's current location
                    (map-set iot-devices
                        {device-id: device-id}
                        (merge device {
                            location-lat: latitude,
                            location-lon: longitude,
                            last-communication: timestamp
                        })
                    )
                    
                    (ok true)
                )
            ERR_DEVICE_NOT_REGISTERED
        )
    )
)

;; Update device battery status
(define-public (update-battery-status (device-id (string-ascii 64)) (battery-level uint))
    (let (
        (device-info (map-get? iot-devices {device-id: device-id}))
    )
        (asserts! (is-some device-info) ERR_DEVICE_NOT_REGISTERED)
        (asserts! (<= battery-level u10000) ERR_INVALID_DATA) ;; Max 100.00%
        
        (match device-info
            device
                (begin
                    (asserts! (is-eq tx-sender (get owner device)) ERR_UNAUTHORIZED)
                    
                    (map-set iot-devices
                        {device-id: device-id}
                        (merge device {
                            battery-level: battery-level,
                            last-communication: stacks-block-height
                        })
                    )
                    
                    ;; Create low battery alert if necessary
                    (if (< battery-level MIN_BATTERY_LEVEL)
                        (let (
                            (alert-id (create-alert 
                                device-id 
                                "battery" 
                                "Low battery warning" 
                                u1 
                                (to-int battery-level) 
                                (to-int MIN_BATTERY_LEVEL)
                            ))
                        )
                            (ok alert-id)
                        )
                        (ok u0)
                    )
                )
            ERR_DEVICE_NOT_REGISTERED
        )
    )
)

;; Configure alert thresholds
(define-public (set-alert-thresholds
    (device-id (string-ascii 64))
    (min-temp int)
    (max-temp int)
    (max-hum uint)
    (max-shock-level uint)
    (max-vib uint)
)
    (let (
        (device-info (map-get? iot-devices {device-id: device-id}))
    )
        (asserts! (is-some device-info) ERR_DEVICE_NOT_REGISTERED)
        
        (match device-info
            device
                (begin
                    (asserts! (is-eq tx-sender (get owner device)) ERR_UNAUTHORIZED)
                    (asserts! (< min-temp max-temp) ERR_INVALID_DATA)
                    
                    (map-set alert-thresholds
                        {device-id: device-id}
                        {
                            min-temperature: min-temp,
                            max-temperature: max-temp,
                            max-humidity: max-hum,
                            max-shock: max-shock-level,
                            max-vibration: max-vib,
                            geofence-enabled: false,
                            geofence-lat: 0,
                            geofence-lon: 0,
                            geofence-radius: u0
                        }
                    )
                    
                    (ok true)
                )
            ERR_DEVICE_NOT_REGISTERED
        )
    )
)

;; Resolve alert
(define-public (resolve-alert (device-id (string-ascii 64)) (alert-id uint))
    (let (
        (alert-info (map-get? device-alerts {device-id: device-id, alert-id: alert-id}))
        (device-info (map-get? iot-devices {device-id: device-id}))
    )
        (asserts! (is-some alert-info) ERR_NOT_FOUND)
        (asserts! (is-some device-info) ERR_DEVICE_NOT_REGISTERED)
        
        (match alert-info alert-data
            (match device-info device-data
                (begin
                    (asserts! (is-eq tx-sender (get owner device-data)) ERR_UNAUTHORIZED)
                    (asserts! (not (get is-resolved alert-data)) ERR_INVALID_DATA)
                    
                    (map-set device-alerts
                        {device-id: device-id, alert-id: alert-id}
                        (merge alert-data {
                            is-resolved: true,
                            resolved-at: stacks-block-height
                        })
                    )
                    
                    (ok true)
                )
                ERR_DEVICE_NOT_REGISTERED
            )
            ERR_NOT_FOUND
        )
    )
)

;; Read-only functions
(define-read-only (get-device-info (device-id (string-ascii 64)))
    (map-get? iot-devices {device-id: device-id})
)

(define-read-only (get-environmental-data (device-id (string-ascii 64)) (timestamp uint))
    (map-get? environmental-data {device-id: device-id, timestamp: timestamp})
)

(define-read-only (get-location-data (device-id (string-ascii 64)) (timestamp uint))
    (map-get? location-tracking {device-id: device-id, timestamp: timestamp})
)

(define-read-only (get-alert-thresholds (device-id (string-ascii 64)))
    (map-get? alert-thresholds {device-id: device-id})
)

(define-read-only (get-device-alert (device-id (string-ascii 64)) (alert-id uint))
    (map-get? device-alerts {device-id: device-id, alert-id: alert-id})
)

(define-read-only (get-platform-statistics)
    {
        total-devices: (var-get total-devices),
        active-devices: (var-get active-devices),
        total-alerts: (var-get total-alerts),
        total-data-points: (var-get total-data-points),
        next-alert-id: (var-get next-alert-id)
    }
)

;; title: container-iot-integration
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; data vars
;;

;; data maps
;;

;; public functions
;;

;; read only functions
;;

;; private functions
;;

