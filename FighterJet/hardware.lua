-- Confirmed discovery data; loading this file does not call peripherals.
-- Up/down refer to the observed trailing-edge movement, not aerodynamic torque.
return {
    typewriter = "linked_typewriter_1",
    engine = "simulated:portable_engine_0",
    fuelStorage = "sophisticatedstorage:barrel_3",
    monitor = "monitor_1",
    navigation = "navigation_table_0",
    keys = { w = 87, a = 65, s = 83, d = 68, space = 32, leftShift = 340 },
    wings = {
        right = {
            gearshift = "directional_gearshift_2", spring = "torsion_spring_0",
            up = { left = true, right = false },
            down = { left = false, right = true },
            upAngleSign = -1,
        },
        left = {
            gearshift = "directional_gearshift_3", spring = "torsion_spring_1",
            up = { left = false, right = true },
            down = { left = true, right = false },
            upAngleSign = 1,
        },
    },
    -- Confirmed rear view looking toward the nose: diamond arrangement.
    thrusters = { "thruster_12", "thruster_13", "thruster_14", "thruster_15" },
    thrusterPositions = { top="thruster_13", bottom="thruster_12", left="thruster_15", right="thruster_14" },
    sensors = { gimbal = "gimbal_sensor_1", velocity = "velocity_sensor_2",
        altitude = "altitude_sensor_1", radar = "create_radar:plane_radar_2" },
}
