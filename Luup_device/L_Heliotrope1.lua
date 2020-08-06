--[[
    Heliotrope (sun follower) plugin.

    This software was originated by Deborah Pickett.
    Copyright (C) 2013 Deborah Pickett:

    Thanks to Deborah for her work on this software. Deborah has kindly
    given permmission (3 Aug 2020) for this modified software to be
    placed on GitHub and linked to the AltApp store.

    Modified and updated by a-lurker, July 2020
    Ver 0.52 released Aug 2020

    Modifications and updates by a-lurker to the orginal program
    is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License
    version 3 (GPLv3) as published by the Free Software Foundation;

    In addition to the GPLv3 License, this software is only for private
    or home useage. Commercial utilisation is not authorized.

    The above copyright notice and this permission notice shall be included
    in all copies or substantial portions of the Software.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.


    Inputs:
        UseAscDec             = '0' or '1':   calculate celestial coordinates or not
        RightAscension_0to360 = '0' or '1':   -180º to 180º or 0º to 360º
        Azimuth_0to360        = '0' or '1':   -180º to 180º or 0º to 360º

        Latitude  = can be customised - defaults to location set in Vera
        Longitude = can be customised - defaults to location set in Vera

    Outputs:
        RightAscension        = celestial coordinates: analogous to terrestrial longitude where the sun is directly overhead: -180º to 180º
        RightAscensionHrs     = hrs:mins:secs  360º/24 = 15º per hour
        RightAscension360     = 0º to 360º
        RightAscensionRounded = rounded to 0.1 degree

        Declination           = analogous to terrestrial latitude where the sun is directly overhead -90º to 90º
        DeclinationRounded    = rounded to 0.1 degree

        Azimuth               = -180º south, -90º west, 0º north , 90º east, 180º south  (aka direction)
        Azimuth360            =  180º south, 270º west, 0º north , 90º east, 180º south
        AzimuthRounded        = rounded to 0.1 degree

        Altitude              = angle between -90° and 90° below/above horizon (aka elevation)
        AltitudeRounded       = rounded to 0.1 degree
]]

local PLUGIN_NAME     = 'Heliotrope'
local PLUGIN_SID      = 'urn:futzle-com:serviceId:'..PLUGIN_NAME..'1'
local PLUGIN_VERSION  = '0.52'
local THIS_LUL_DEVICE = nil

local m_pollInterval  = 30   -- seconds
local m_latitude      = 0
local m_longitude     = 0
local m_useAscDec     = true
local m_RA_use360     = true
local m_Az_use360     = true

 -- Set this to false if 6 decimal places aren't needed. The idea is
 -- to be able to reduce the number of writes to the log, if desired.
 -- The UseAscDec variable can also totally shut down the asc/dec info.
local m_to6decimals = true

-- Extend luup.variable_set() with variableSet()
local function variableSet (k, v)
    --luup.log (k..' = '..tostring(v),50)
    luup.variable_set(PLUGIN_SID, k, v, THIS_LUL_DEVICE)
end

-- Return altitude correction for altitude due to atmospheric refraction
-- http://en.wikipedia.org/wiki/Atmospheric_refraction
local function correctForRefraction(d)
    if (not (d > -0.5)) then d = -0.5 end    -- function goes ballistic when negative
    return (0.017 / math.tan(math.rad(d + 10.3 / (d+5.11))))
end

-- Return the right ascension of the sun at Unix epoch t.
-- http://www.stargazing.net/kepler/sun.html#twig02
local function sunAbsolutePositionDeg(t)
    local dSec                 = t - 946728000   -- 946728000 is exactly thirty Julian years where a year is 365.25 Julian days
    local meanLongitudeDeg     = (280.461 + (0.9856474 * dSec)/86400.0) % 360.0
    local meanAnomalyRad       = math.rad((357.528 + (0.9856003 * dSec)/86400.0) % 360.0)
    local eclipticLongitudeRad = math.rad(meanLongitudeDeg + (1.915 * math.sin(meanAnomalyRad)) + (0.020 * math.sin(2*meanAnomalyRad)))
    local eclipticObliquityRad = math.rad(23.439 - (0.0000004 * dSec)/86400.0)
    local sunAbsY              = math.cos(eclipticObliquityRad) * math.sin(eclipticLongitudeRad)
    local sunAbsX              = math.cos(eclipticLongitudeRad)
    local rightAscensionRad    = math.atan2(sunAbsY, sunAbsX)
    local declinationRad       = math.asin(math.sin(eclipticObliquityRad)*math.sin(eclipticLongitudeRad))

    return math.deg(rightAscensionRad), math.deg(declinationRad)
end

-- Convert an object's RA/Dec to alt azimuth coordinates
-- http://www.stargazing.net/kepler/sun.html#twig02
-- http://answers.yahoo.com/question/index?qid=20070830185150AAoNT4i
-- http://www.jgiesen.de/astro/astroJS/siderealClock/
local function absoluteToRelativeDeg(t, rightAscensionDeg, declinationDeg)
    local declinationRad   = math.rad(declinationDeg)
    local m_latitudeRad    = math.rad(m_latitude)
    local dSec             = t - 946728000   -- 946728000 is exactly thirty Julian years where a year is 365.25 Julian days
    local midnightUtc      = dSec - (dSec % 86400)   -- 86400 seconds in 24 hours ie one Julian day
    local siderialUtcHours = (18.697374558 + (0.06570982441908 * midnightUtc) / 86400.0 + (1.00273790935 * (dSec%86400)) / 3600) % 24.0
    local siderialLocalDeg = (siderialUtcHours * 15 + m_longitude) % 360.0
    local hourAngleRad     = math.rad((siderialLocalDeg - rightAscensionDeg) % 360.0)
    local altitudeRad      = math.asin(math.sin(declinationRad) * math.sin(m_latitudeRad) + math.cos(declinationRad) * math.cos(m_latitudeRad) * math.cos(hourAngleRad))
    local azimuthY         = -math.cos(declinationRad) * math.cos(m_latitudeRad) * math.sin(hourAngleRad)
    local azimuthX         =  math.sin(declinationRad) - math.sin(m_latitudeRad) * math.sin(altitudeRad)
    local azimuthRad       = math.atan2(azimuthY, azimuthX)

    return math.deg(azimuthRad), math.deg(altitudeRad)
end

-- Get the result after each poll interval
-- Must be global: delay timeout target
function pollHeliotrope()
    local t = os.time()
    local ra, dec = sunAbsolutePositionDeg(t)

    if (m_useAscDec) then
        local ra360 = ra
        if (0 > ra360) then ra360 = ra360 + 360.0 end

        if (m_to6decimals) then
            variableSet('RightAscension',    string.format('%f', ra))
            variableSet('RightAscension360', string.format('%f', ra360))
            variableSet('Declination',       string.format('%f', dec))
        end

        local raRounded = ''
        if (m_RA_use360) then
            raRounded = string.format('%.1f', ra360)
        else
            raRounded = string.format('%.1f', ra)
        end

        local decRounded = string.format('%.1f', dec)

        variableSet('RightAscensionRounded', raRounded)
        variableSet('DeclinationRounded', decRounded)
        local hrs,  f = math.modf(ra/15)
        local mins, f = math.modf(f*60)
        local secs    = f*60
        variableSet('RightAscensionHrs', string.format('%.0fh %.0fm %.1fs', hrs, mins, secs))
    end

    local az, alt = absoluteToRelativeDeg(t, ra, dec)
    alt = alt + correctForRefraction(alt)

    local az360 = az
    if (0 > az360) then az360 = az360 + 360.0 end

    if (m_to6decimals) then
        variableSet('Azimuth',    string.format('%f', az))
        variableSet('Azimuth360', string.format('%f', az360))
    end

    local azRounded = ''
    if (m_Az_use360) then
        azRounded = string.format('%.1f', az360)
    else
        azRounded = string.format('%.1f', az)
    end

    variableSet('AzimuthRounded', azRounded)
    variableSet('Altitude', string.format('%f', alt))

    local altRounded = string.format('%.1f', alt)
    variableSet('AltitudeRounded', altRounded)

    -- get the result after each poll interval
    luup.call_delay('pollHeliotrope', m_pollInterval)
end

-- Let's do it
-- Function must be global
function luaStartUp(lul_device)
    THIS_LUL_DEVICE = lul_device

    luup.log('Heliotrope start',50)

    -- set up some defaults:
    variableSet('PluginVersion', PLUGIN_VERSION)

    local pluginEnabled = luup.variable_get(PLUGIN_SID, 'PluginEnabled',         THIS_LUL_DEVICE)
    local latitude      = luup.variable_get(PLUGIN_SID, 'Latitude',              THIS_LUL_DEVICE)
    local longitude     = luup.variable_get(PLUGIN_SID, 'Longitude',             THIS_LUL_DEVICE)
    local useAscDec     = luup.variable_get(PLUGIN_SID, 'UseAscDec',             THIS_LUL_DEVICE)
    local RA_use360     = luup.variable_get(PLUGIN_SID, 'RightAscension_0to360', THIS_LUL_DEVICE)
    local Az_use360     = luup.variable_get(PLUGIN_SID, 'Azimuth_0to360',        THIS_LUL_DEVICE)

    if not((pluginEnabled == '0') or (pluginEnabled == '1')) then
        pluginEnabled = '1'
        variableSet('PluginEnabled', pluginEnabled)
    end
    if (pluginEnabled ~= '1') then return true, 'All OK', PLUGIN_NAME end

    latitude = tonumber(latitude)
    if (latitude == nil) then
        m_latitude = luup.latitude
        variableSet('Latitude', m_latitude)
    else
        m_latitude = latitude
    end

    longitude = tonumber(longitude)
    if (longitude == nil) then
        m_longitude = luup.longitude
        variableSet('Longitude', m_longitude)
    else
        m_longitude = longitude
    end

    if not((useAscDec == '0') or (useAscDec == '1')) then
        -- the user must set this to '1' if they are really interested in using asc/dec
        useAscDec = '0'
        variableSet('UseAscDec', useAscDec)
    end
    m_useAscDec = (useAscDec == '1')

    if not((RA_use360 == '0') or (RA_use360 == '1')) then
        -- celestial coordinates use 0º to 360º or hours at 15º per hour
        RA_use360 = '1'
        variableSet('RightAscension_0to360', RA_use360)
    end
    m_RA_use360 = (RA_use360 == '1')

    if not((Az_use360 == '0') or (Az_use360 == '1')) then
        Az_use360 = '1'  -- zero to 360 degrees is typically used
        variableSet('Azimuth_0to360', Az_use360)
    end
    m_Az_use360 = (Az_use360 == '1')

    -- blank these out when asc/dec is not in use so
    -- the control panel doesn't show any garbage
    if (not m_useAscDec) then
        variableSet('RightAscensionHrs',     '----')
        variableSet('RightAscensionRounded', '----')
        variableSet('DeclinationRounded',    '----')
    end

    -- 4 second timer to get initial data
    luup.call_delay('pollHeliotrope', 4)

    -- required for UI7. UI5 uses true or false for the passed parameter.
    -- UI7 uses 0 or 1 or 2 for the parameter. This works for both UI5 and UI7
    luup.set_failure(false)

    -- startup is done
    return true, 'All OK', PLUGIN_NAME
end
