return {
    -- Confirmed roles: 5 owns flight/autopilot; 6 owns display/configuration UI.
    flightID = 5, hudID = 6, modem = "bottom",
    staleSeconds = 2, sensorInterval = 0.5,
    inventoryInterval = 2, radarInterval = 1,
    monitor = "monitor_1", textScale = 0.5,
    radar = "create_radar:plane_radar_2",
    altitude = "altitude_sensor_1", velocity = "velocity_sensor_2",
    gimbal = "gimbal_sensor_1", typewriter = "linked_typewriter_1",
    engine = "simulated:portable_engine_0", barrel = "sophisticatedstorage:barrel_3",
    thrusters = { "thruster_12", "thruster_13", "thruster_14", "thruster_15" },
    -- Exact radar entityType -> player / hostile / passive / structure / unknown.
    -- Add structure entity identifiers once they appear in actual radar data.
    entityKinds = {},
    ranges = { 50, 100, 250 },
    -- Variable individual engine power; Space still requests full base thrust.
    vectoring = { enabled=true, authority=0.25, pitchSign=1, yawSign=1,
        top="thruster_13", bottom="thruster_12", left="thruster_15", right="thruster_14" },
    navigation = "navigation_table_0", -- optional marker import only
    position = { name="directional_gearshift_2", method="getPosition" },
    homeDimension = "minecraft:overworld",
    -- Direct adjacent-computer access; verify getID before power actions.
    flightPeer = "right", hudPeer = "left",
    linkTimeout = 3, requestMaxAge = 2,
    recovery = { autoRestartHUD=true, grace=30, timeout=10, cooldown=60, maxAttempts=3 },
    -- Optional overrides for explicit /fighter/run assist; existing configs need no edits.
    -- Defaults in flight_core.assistConfig use pitch=+GZ, bank=-GX, 40-degree surfaces.
    assist = { pitchRateLimit=25, bankRateLimit=40, pitchKp=0.6, bankKp=0.6,
        pitchKd=0.5, bankKd=0.4, rateFilter=0.15 },
    flight = {
        -- Set true only after checking these axes/signs and all four thrust directions.
        calibrated=false, thrustersVerified=false,
        pitchAxis=2, bankAxis=1, pitchSign=1, bankSign=1,
        pitchOffset=0, bankOffset=0,
        pitchSurfaceSign=1, bankSurfaceSign=-1, -- observed wing roll response
        -- Positive surfaces mean trailing edge UP. Mechanical signs are tested.
        maxSurface=10, pitchKp=0.5, pitchKd=0.15, bankKp=0.5, bankKd=0.15,
        rateFilter=0.25, pitchLead=12, bankLead=20, maxPitch=60,
        cruiseAltitude=150, minAltitude=-64, maxAltitude=1000,
        altitudeKp=0.15, altitudeKd=0.4, maxAPPitch=15, maxAPBank=25,
        courseKp=0.6, courseMinSpeed=2, courseInterval=0.5, courseMaxAge=2,
        arrivalRadius=40, period=0.1, outputTimeout=2,
    },
}
