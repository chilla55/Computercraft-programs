"""Read-only numerical analysis of Power Grid v0.6.2; not controller protection.

Source commit d681ac986adb92553ed4177c57e2e02bedb01672 (MC 1.20.1).
Reproduce with: python3 Powerplant/regulator/analysis/variac_thermal_v062.py
Java float rounding is reproduced for refreshed circuit parameters. Electrical
branch calculations and the reported steady-state temperature use double math.
Assumes steady forward DC operation, no fan cooling, and heat-before-cool ticks.
"""
import math
import struct


def f32(value):
    return struct.unpack('f', struct.pack('f', value))[0]


def refreshed_parameters(position, mutual_multiplier=10):
    ratio = f32(f32(f32(position) * f32(.99)) + f32(.01))
    primary_inductance = f32(25 * 25 * 1.5)
    turns = f32(ratio * 25)
    secondary_inductance = f32(f32(turns * turns) * f32(1.5))
    ratio_squared = f32(ratio * ratio)
    mutual = f32(f32(secondary_inductance / ratio_squared) * f32(.9999))
    primary_stray = f32(primary_inductance - mutual)
    secondary_stray = f32(secondary_inductance - f32(ratio_squared * mutual))
    coupling_resistance = f32(f32(secondary_stray * ratio) * ratio)
    return ratio, primary_stray, f32(mutual * mutual_multiplier), coupling_resistance


def analyze(output_voltage, output_current, position=1, ambient=18.02,
            mutual_multiplier=10, configured_loss_power=1000, thermal_mass=4,
            cooling_multiplier=1, overheat_temperature=175):
    ratio, primary_resistance, magnetizing_resistance, coupling_resistance = refreshed_parameters(position, mutual_multiplier)
    internal_voltage = (output_voltage + coupling_resistance * output_current) / ratio
    magnetizing_current = internal_voltage / magnetizing_resistance
    primary_current = ratio * output_current + magnetizing_current
    copper_loss = primary_current ** 2 * primary_resistance
    magnetizing_loss = internal_voltage ** 2 / magnetizing_resistance
    loss = copper_loss + magnetizing_loss
    cooling = configured_loss_power / (overheat_temperature - 25 - 22) * cooling_multiplier
    fraction = cooling / (20 * thermal_mass)
    assert 0 < fraction < 1, 'This steady-state expression assumes an unclamped cooling step'
    temperature = ambient + (1 - fraction) * loss / cooling
    return dict(input_voltage=internal_voltage + primary_resistance * primary_current,
                primary_current=primary_current, copper_loss=copper_loss,
                magnetizing_loss=magnetizing_loss, loss=loss, temperature=temperature,
                ambient=ambient, cooling=cooling, thermal_mass=thermal_mass,
                smoke_temperature=overheat_temperature - 50)


def iterate_temperature(loss, ambient, cooling, thermal_mass, ticks=1000):
    temperature = ambient
    for _ in range(ticks):
        temperature += loss / (20 * thermal_mass)
        temperature -= cooling * (temperature - ambient) / (20 * thermal_mass)
    return temperature


if __name__ == '__main__':
    print('v0.6.2 refreshed model; default thermal settings; assumed ambient 18.02 C')
    print('Position 1 parameters (ratio, primary R, magnetizing R, coupling R):')
    print(refreshed_parameters(1))
    measurements = [
        (2794.067626953125, 30.973, None),
        (981.9259033203125, 93.303, None),
        (1985.8565673828125, 72.945, 124.9),
        (2793.994873046875, 30.864, 124.9),
    ]
    for voltage, current, observed in measurements:
        result = analyze(voltage, current)
        iterated = iterate_temperature(result['loss'], result['ambient'], result['cooling'], result['thermal_mass'])
        assert math.isclose(iterated, result['temperature'], abs_tol=1e-8)
        print(f'{voltage:.6f} V, {current:.3f} A: '
              f"heat {result['loss']:.6f} W, predicted {result['temperature']:.6f} C, observed {observed}")
    print('Closed-form temperatures agree with the discrete tick recurrence.')
