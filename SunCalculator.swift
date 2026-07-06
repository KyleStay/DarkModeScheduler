import Foundation

/// The result of a single sun event (sunrise or sunset) for a location/date.
///
/// Most inhabited locations always produce a concrete `.time`. The polar
/// cases only occur at extreme latitudes (never for US zipcodes) but are
/// modeled explicitly so callers can fall back sensibly.
enum SunEvent: Equatable {
    case time(Date)
    case alwaysUp    // Polar day: the sun never dips below the horizon.
    case alwaysDown  // Polar night: the sun never rises above the horizon.
}

/// Sunrise and sunset for one calendar date at one location.
struct SunTimes: Equatable {
    let sunrise: SunEvent
    let sunset: SunEvent
}

/// Pure, local implementation of the NOAA sunrise/sunset algorithm.
///
/// No I/O, no global state, no network. Given a latitude, longitude
/// (degrees, west negative), a date, and a time zone, it returns today's
/// sunrise and sunset as `Date`s expressed in that time zone's wall-clock
/// time (DST-aware).
///
/// The math mirrors NOAA's published Solar Calculations spreadsheet
/// (https://gml.noaa.gov/grad/solcalc/calcdetails.html). Solar quantities
/// are evaluated once at local solar noon; over the few hours to sunrise/
/// sunset this single-pass approximation stays well within ~1 minute, which
/// satisfies our ±2 minute correctness bar.
enum SunCalculator {

    /// Zenith angle (degrees) of the sun's center at apparent sunrise/sunset,
    /// including the standard allowances for atmospheric refraction (~34') and
    /// the sun's semidiameter (~16').
    private static let officialZenith = 90.833

    static func deg2rad(_ d: Double) -> Double { d * .pi / 180.0 }
    static func rad2deg(_ r: Double) -> Double { r * 180.0 / .pi }

    /// Julian Day Number at 12:00 UT for a Gregorian calendar date.
    /// (JD = 2451545.0 for 2000-01-01 12:00 UT.)
    static func julianDayNumber(year: Int, month: Int, day: Int) -> Int {
        let a = (14 - month) / 12
        let y = year + 4800 - a
        let m = month + 12 * a - 3
        return day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
    }

    /// Compute sunrise & sunset for the calendar date that contains `date`,
    /// at the given latitude/longitude, returned in `timeZone` wall-clock time.
    ///
    /// - Parameters:
    ///   - latitude: degrees north (positive) / south (negative).
    ///   - longitude: degrees east (positive) / west (negative).
    ///   - date: any instant on the target calendar day.
    ///   - timeZone: time zone used to resolve the calendar day and to express
    ///     the returned `Date`s (its DST-aware offset is applied).
    static func sunTimes(latitude: Double,
                         longitude: Double,
                         date: Date,
                         timeZone: TimeZone) -> SunTimes {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = comps.year, let month = comps.month, let day = comps.day,
              let localMidnight = calendar.date(from: DateComponents(year: year,
                                                                     month: month,
                                                                     day: day)) else {
            // Should be unreachable for valid dates; fail closed to "always dark".
            return SunTimes(sunrise: .alwaysDown, sunset: .alwaysDown)
        }

        // Actual UTC offset (hours) for this local day — automatically DST-aware.
        let tzOffsetHours = Double(timeZone.secondsFromGMT(for: localMidnight)) / 3600.0

        // Julian Day / Century evaluated at local solar noon.
        let jdn = julianDayNumber(year: year, month: month, day: day)
        let jd = Double(jdn) - tzOffsetHours / 24.0
        let t = (jd - 2451545.0) / 36525.0  // Julian centuries since J2000.0

        // --- Solar position (NOAA spreadsheet columns I..W) ---
        let geomMeanLong = fmod(280.46646 + t * (36000.76983 + t * 0.0003032), 360.0)
        let geomMeanAnom = 357.52911 + t * (35999.05029 - 0.0001537 * t)
        let eccent = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)

        let sunEqOfCenter =
            sin(deg2rad(geomMeanAnom)) * (1.914602 - t * (0.004817 + 0.000014 * t)) +
            sin(deg2rad(2 * geomMeanAnom)) * (0.019993 - 0.000101 * t) +
            sin(deg2rad(3 * geomMeanAnom)) * 0.000289

        let sunTrueLong = geomMeanLong + sunEqOfCenter
        let sunAppLong = sunTrueLong - 0.00569 - 0.00478 * sin(deg2rad(125.04 - 1934.136 * t))

        let meanObliq = 23.0 + (26.0 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60.0) / 60.0
        let obliqCorr = meanObliq + 0.00256 * cos(deg2rad(125.04 - 1934.136 * t))

        let sunDeclin = rad2deg(asin(sin(deg2rad(obliqCorr)) * sin(deg2rad(sunAppLong))))

        let varY = tan(deg2rad(obliqCorr / 2)) * tan(deg2rad(obliqCorr / 2))
        let eqOfTime = 4 * rad2deg(
            varY * sin(2 * deg2rad(geomMeanLong)) -
            2 * eccent * sin(deg2rad(geomMeanAnom)) +
            4 * eccent * varY * sin(deg2rad(geomMeanAnom)) * cos(2 * deg2rad(geomMeanLong)) -
            0.5 * varY * varY * sin(4 * deg2rad(geomMeanLong)) -
            1.25 * eccent * eccent * sin(2 * deg2rad(geomMeanAnom)))

        // Hour angle (degrees) from solar noon to sunrise/sunset.
        let cosHourAngle =
            cos(deg2rad(officialZenith)) / (cos(deg2rad(latitude)) * cos(deg2rad(sunDeclin))) -
            tan(deg2rad(latitude)) * tan(deg2rad(sunDeclin))

        // Solar noon expressed as a fraction of the local day.
        let solarNoonMinutes = 720.0 - 4.0 * longitude - eqOfTime + tzOffsetHours * 60.0
        let solarNoonFrac = solarNoonMinutes / 1440.0

        func localDate(fromDayFraction frac: Double) -> Date {
            localMidnight.addingTimeInterval(frac * 86400.0)
        }

        if cosHourAngle > 1.0 {
            // Sun stays below the horizon all day → polar night.
            return SunTimes(sunrise: .alwaysDown, sunset: .alwaysDown)
        } else if cosHourAngle < -1.0 {
            // Sun stays above the horizon all day → polar day.
            return SunTimes(sunrise: .alwaysUp, sunset: .alwaysUp)
        }

        let hourAngle = rad2deg(acos(cosHourAngle))       // degrees
        let sunriseFrac = solarNoonFrac - hourAngle * 4.0 / 1440.0
        let sunsetFrac = solarNoonFrac + hourAngle * 4.0 / 1440.0

        return SunTimes(sunrise: .time(localDate(fromDayFraction: sunriseFrac)),
                        sunset: .time(localDate(fromDayFraction: sunsetFrac)))
    }
}
