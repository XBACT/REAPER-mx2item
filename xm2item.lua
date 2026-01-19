local script_name = "xm2item"

local function read_u1(file)
  local byte = file:read(1)
  if not byte then return nil end
  return string.byte(byte)
end

local function read_u2le(file)
  local b1, b2 = file:read(1), file:read(1)
  if not b1 or not b2 then return nil end
  return string.byte(b1) + string.byte(b2) * 256
end

local function read_u4le(file)
  local b1, b2, b3, b4 = file:read(1), file:read(1), file:read(1), file:read(1)
  if not b1 or not b4 then return nil end
  return string.byte(b1) + string.byte(b2) * 256 + string.byte(b3) * 65536 + string.byte(b4) * 16777216
end

local function read_s1(file)
  local val = read_u1(file)
  if not val then return nil end
  if val >= 128 then val = val - 256 end
  return val
end

local function read_string(file, len)
  local str = file:read(len)
  if not str then return "" end
  local null_pos = str:find("\0")
  if null_pos then str = str:sub(1, null_pos - 1) end
  return str
end

local function skip_bytes(file, count)
  file:read(count)
end

local NOTE_NAMES = {"C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"}

local function xm_note_to_name(xm_note)
  -- XM note 1 = C-0, note 13 = C-1, etc.
  if xm_note == 0 then return "---" end
  if xm_note == 97 then return "===" end
  
  local note_idx = ((xm_note - 1) % 12) + 1
  local octave = math.floor((xm_note - 1) / 12)
  return NOTE_NAMES[note_idx] .. octave
end

local function xm_note_to_semitones_from_c4(xm_note)
  -- XM C-4 = note 49
  if xm_note == 0 or xm_note == 97 then
    return nil
  end
  return xm_note - 49
end


local XMParser = {}
XMParser.__index = XMParser

function XMParser.new()
  local self = setmetatable({}, XMParser)
  self.module_name = ""
  self.tracker_name = ""
  self.version_major = 0
  self.version_minor = 0
  self.song_length = 0
  self.restart_position = 0
  self.num_channels = 0
  self.num_patterns = 0
  self.num_instruments = 0
  self.freq_table_type = 0
  self.default_tempo = 6
  self.default_bpm = 125
  self.pattern_order = {}
  self.patterns = {}
  self.instruments = {}
  return self
end

function XMParser:parse(filepath)
  local file = io.open(filepath, "rb")
  if not file then
    return false, "Cannot open file: " .. filepath
  end
  
  local signature = file:read(17)
  if signature ~= "Extended Module: " then
    file:close()
    return false, "Invalid XM file signature"
  end
  
  self.module_name = read_string(file, 20)
  
  local sig1 = read_u1(file)
  if sig1 ~= 0x1A then
    file:close()
    return false, "Invalid XM signature byte"
  end
  
  self.tracker_name = read_string(file, 20)
  self.version_minor = read_u1(file)
  self.version_major = read_u1(file)
  
  local header_size = read_u4le(file)
  local header_start = file:seek()
  
  self.song_length = read_u2le(file)
  self.restart_position = read_u2le(file)
  self.num_channels = read_u2le(file)
  self.num_patterns = read_u2le(file)
  self.num_instruments = read_u2le(file)
  
  local flags = read_u2le(file)
  self.freq_table_type = (flags & 1)
  
  self.default_tempo = read_u2le(file)
  self.default_bpm = read_u2le(file)
  
  self.pattern_order = {}
  for i = 1, 256 do
    self.pattern_order[i] = read_u1(file)
  end
  
  file:seek("set", header_start - 4 + header_size)
  
  for p = 1, self.num_patterns do
    self.patterns[p] = self:parse_pattern(file)
  end
  
  for i = 1, self.num_instruments do
    self.instruments[i] = self:parse_instrument(file)
  end
  
  file:close()
  return true
end

function XMParser:parse_pattern(file)
  local pattern = {}
  
  local header_length = read_u4le(file)
  if not header_length then
    pattern.num_rows = 64
    pattern.rows = {}
    for row = 1, 64 do
      pattern.rows[row] = {}
      for ch = 1, self.num_channels do
        pattern.rows[row][ch] = {
          note = 0, instrument = 0, volume = 0,
          effect_type = 0, effect_param = 0
        }
      end
    end
    return pattern
  end
  
  local packing_type = read_u1(file) or 0
  
  local num_rows
  if self.version_major == 1 and self.version_minor == 2 then
    num_rows = (read_u1(file) or 63) + 1
  else
    num_rows = read_u2le(file) or 64
  end
  
  local packed_size = read_u2le(file) or 0
  
  pattern.num_rows = num_rows
  pattern.rows = {}
  
  if packed_size == 0 then
    for row = 1, num_rows do
      pattern.rows[row] = {}
      for ch = 1, self.num_channels do
        pattern.rows[row][ch] = {
          note = 0, instrument = 0, volume = 0,
          effect_type = 0, effect_param = 0
        }
      end
    end
    return pattern
  end
  
  local packed_data = file:read(packed_size)
  if not packed_data then
    for row = 1, num_rows do
      pattern.rows[row] = {}
      for ch = 1, self.num_channels do
        pattern.rows[row][ch] = {
          note = 0, instrument = 0, volume = 0,
          effect_type = 0, effect_param = 0
        }
      end
    end
    return pattern
  end
  
  local pos = 1
  
  local function get_byte()
    if not packed_data or pos > #packed_data then return 0 end
    local b = string.byte(packed_data, pos)
    pos = pos + 1
    return b
  end
  
  for row = 1, num_rows do
    pattern.rows[row] = {}
    for ch = 1, self.num_channels do
      local note, instrument, volume, effect_type, effect_param = 0, 0, 0, 0, 0
      
      local first_byte = get_byte()
      
      if first_byte & 0x80 ~= 0 then
        if first_byte & 0x01 ~= 0 then note = get_byte() end
        if first_byte & 0x02 ~= 0 then instrument = get_byte() end
        if first_byte & 0x04 ~= 0 then volume = get_byte() end
        if first_byte & 0x08 ~= 0 then effect_type = get_byte() end
        if first_byte & 0x10 ~= 0 then effect_param = get_byte() end
      else
        note = first_byte
        instrument = get_byte()
        volume = get_byte()
        effect_type = get_byte()
        effect_param = get_byte()
      end
      
      pattern.rows[row][ch] = {
        note = note,
        instrument = instrument,
        volume = volume,
        effect_type = effect_type,
        effect_param = effect_param
      }
    end
  end
  
  return pattern
end

function XMParser:parse_instrument(file)
  local instrument = {}
  
  local inst_header_size = read_u4le(file)
  if not inst_header_size then
    instrument.name = ""
    instrument.type = 0
    instrument.num_samples = 0
    instrument.samples = {}
    instrument.sample_headers = {}
    return instrument
  end
  
  local inst_header_start = file:seek()
  
  instrument.name = read_string(file, 22)
  instrument.type = read_u1(file) or 0
  instrument.num_samples = read_u2le(file) or 0
  
  instrument.samples = {}
  instrument.sample_headers = {}
  
  if instrument.num_samples > 0 then
    local sample_header_size = read_u4le(file)
    skip_bytes(file, 96)
    skip_bytes(file, 48)
    skip_bytes(file, 48)
    skip_bytes(file, 14)
    skip_bytes(file, 4)
    skip_bytes(file, 2)
    skip_bytes(file, 2)
  end
  
  file:seek("set", inst_header_start - 4 + inst_header_size)

  local total_sample_data = 0
  for s = 1, instrument.num_samples do
    local length = read_u4le(file) or 0
    skip_bytes(file, 4)
    skip_bytes(file, 4) 
    skip_bytes(file, 1)
    skip_bytes(file, 1)
    local type_byte = read_u1(file) or 0
    local is_16bit = (type_byte & 0x10) ~= 0
    skip_bytes(file, 1)
    skip_bytes(file, 1)
    skip_bytes(file, 1)
    skip_bytes(file, 22)
    
    if is_16bit then
      total_sample_data = total_sample_data + length * 2
    else
      total_sample_data = total_sample_data + length
    end
  end
  
  skip_bytes(file, total_sample_data)
  
  return instrument
end

local function collect_instruments_per_channel(xm)
  local channel_instruments = {}
  for ch = 1, xm.num_channels do
    channel_instruments[ch] = {}
  end
  
  local last_instrument = {}
  
  for order_idx = 1, xm.song_length do
    local pattern_idx = xm.pattern_order[order_idx] + 1
    local pattern = xm.patterns[pattern_idx]
    
    if pattern then
      for row_idx = 1, pattern.num_rows do
        for ch = 1, xm.num_channels do
          local cell = pattern.rows[row_idx][ch]
          
          if cell.note > 0 and cell.note < 97 then
            local inst_num = cell.instrument
            if inst_num == 0 then
              inst_num = last_instrument[ch] or 1
            else
              last_instrument[ch] = inst_num
            end
            
            channel_instruments[ch][inst_num] = true
          end
        end
      end
    end
  end
  
  local result = {}
  for ch = 1, xm.num_channels do
    result[ch] = {}
    for inst_num, _ in pairs(channel_instruments[ch]) do
      table.insert(result[ch], inst_num)
    end
    table.sort(result[ch])
  end
  
  return result
end

local function import_xm_to_reaper(xm)
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  
  reaper.SetCurrentBPM(0, xm.default_bpm, false)
  
  local current_tempo = xm.default_tempo
  local current_bpm = xm.default_bpm
  local seconds_per_row = (2.5 / current_bpm) * current_tempo
  
  local channel_instruments = collect_instruments_per_channel(xm)
  
  local tracks = {} 
  local parent_tracks = {} 
  local track_offset = reaper.CountTracks(0)
  local current_track_idx = track_offset
  
  for ch = 1, xm.num_channels do
    tracks[ch] = {}
    local instruments_in_channel = channel_instruments[ch]
    local num_instruments = #instruments_in_channel
    
    reaper.InsertTrackAtIndex(current_track_idx, true)
    local parent_track = reaper.GetTrack(0, current_track_idx)
    reaper.GetSetMediaTrackInfo_String(parent_track, "P_NAME", 
      string.format("[%s] Ch %02d", xm.module_name:sub(1, 8), ch), true)
    
    local pan = 0
    if xm.num_channels >= 4 then
      local ch_mod = (ch - 1) % 4
      if ch_mod == 0 or ch_mod == 3 then pan = -0.5
      else pan = 0.5 end
    end
    reaper.SetMediaTrackInfo_Value(parent_track, "D_PAN", pan)
    
    parent_tracks[ch] = parent_track
    current_track_idx = current_track_idx + 1
    
    if num_instruments <= 1 then
      local inst_num = instruments_in_channel[1] or 1
      tracks[ch][inst_num] = parent_track
    else
      reaper.SetMediaTrackInfo_Value(parent_track, "I_FOLDERDEPTH", 1) 
      
      for i, inst_num in ipairs(instruments_in_channel) do
        reaper.InsertTrackAtIndex(current_track_idx, true)
        local child_track = reaper.GetTrack(0, current_track_idx)
        
        local inst_name = ""
        if xm.instruments[inst_num] then
          inst_name = xm.instruments[inst_num].name or ""
        end
        if inst_name == "" then
          inst_name = string.format("Inst %02d", inst_num)
        end
        
        reaper.GetSetMediaTrackInfo_String(child_track, "P_NAME", 
          string.format("I%02d: %s", inst_num, inst_name), true)
        
        local color = reaper.ColorToNative((inst_num * 37) % 256, 
                                            (inst_num * 73) % 256, 
                                            (inst_num * 113) % 256) | 0x1000000
        reaper.SetMediaTrackInfo_Value(child_track, "I_CUSTOMCOLOR", color)
        
        if i == num_instruments then
          reaper.SetMediaTrackInfo_Value(child_track, "I_FOLDERDEPTH", -1)
        end
        
        tracks[ch][inst_num] = child_track
        current_track_idx = current_track_idx + 1
      end
    end
  end
  
  local current_time = 0
  local active_notes = {}
  local last_instrument = {}
  local items_created = 0
  
  local function create_item_for_note(an, ch)
    if an.end_time <= an.start_time then return end
    
    local target_track = tracks[ch][an.instrument]
    if not target_track then
      target_track = parent_tracks[ch]
    end
    
    local item = reaper.AddMediaItemToTrack(target_track)
    if item then
      reaper.SetMediaItemPosition(item, an.start_time, false)
      reaper.SetMediaItemLength(item, an.end_time - an.start_time, false)
      reaper.SetMediaItemInfo_Value(item, "D_PLAYRATE", 1.0)
      
      local color = reaper.ColorToNative((an.instrument * 37) % 256, 
                                          (an.instrument * 73) % 256, 
                                          (an.instrument * 113) % 256) | 0x1000000
      reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", color)
      
      local semitones = xm_note_to_semitones_from_c4(an.xm_note)
      local note_info = string.format(
        "Note: %s\nInstrument: %d\nPitch: %+d st\nVolume: %d",
        xm_note_to_name(an.xm_note),
        an.instrument,
        semitones or 0,
        an.volume
      )
      reaper.GetSetMediaItemInfo_String(item, "P_NOTES", note_info, true)
      
      local take = reaper.AddTakeToMediaItem(item)
      if take then
        reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME",
          string.format("%s I%02d V%02d", 
            xm_note_to_name(an.xm_note), 
            an.instrument, 
            an.volume), true)
        
        if semitones then
          reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", semitones)
        end
        
        reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", an.volume / 64)
      end
      
      items_created = items_created + 1
    end
  end
  
  for order_idx = 1, xm.song_length do
    local pattern_idx = xm.pattern_order[order_idx] + 1
    local pattern = xm.patterns[pattern_idx]
    
    if pattern then
      local row_times = {}
      local accumulated_time = current_time
      
      for row_idx = 1, pattern.num_rows do
        row_times[row_idx] = accumulated_time
        
        for ch = 1, xm.num_channels do
          local cell = pattern.rows[row_idx][ch]
          if cell.effect_type == 0xF and cell.effect_param > 0 then
            if cell.effect_param < 0x20 then
              current_tempo = cell.effect_param
            else
              current_bpm = cell.effect_param
            end
          end
        end
        
        seconds_per_row = (2.5 / current_bpm) * current_tempo
        accumulated_time = accumulated_time + seconds_per_row
      end
      
      local pattern_end_time = accumulated_time
      
      for row_idx = 1, pattern.num_rows do
        local row_time = row_times[row_idx]
        
        for ch, cell in ipairs(pattern.rows[row_idx]) do
          local note_delay = 0
          local note_cut = nil
          
          if cell.effect_type == 0xE then
            local ext_cmd = math.floor(cell.effect_param / 16)
            local ext_val = cell.effect_param % 16
            
            if ext_cmd == 0xD then
              note_delay = ext_val * (seconds_per_row / current_tempo)
            elseif ext_cmd == 0xC then
              note_cut = ext_val * (seconds_per_row / current_tempo)
            end
          end
          
          if cell.note > 0 and cell.note < 97 then
            if active_notes[ch] then
              local an = active_notes[ch]
              an.end_time = row_time + note_delay
              create_item_for_note(an, ch)
              active_notes[ch] = nil
            end
            
            local inst_num = cell.instrument
            if inst_num == 0 then
              inst_num = last_instrument[ch] or 1
            else
              last_instrument[ch] = inst_num
            end
            
            local volume = 64
            if cell.volume >= 0x10 and cell.volume <= 0x50 then
              volume = cell.volume - 0x10
            end
            if cell.effect_type == 0xC then
              volume = math.min(64, cell.effect_param)
            end
            
            active_notes[ch] = {
              start_time = row_time + note_delay,
              end_time = pattern_end_time,
              instrument = inst_num,
              xm_note = cell.note,
              volume = volume
            }
            
            if note_cut then
              active_notes[ch].end_time = row_time + note_delay + note_cut
            end
            
          elseif cell.note == 97 then
            if active_notes[ch] then
              local an = active_notes[ch]
              an.end_time = row_time + note_delay
              create_item_for_note(an, ch)
              active_notes[ch] = nil
            end
            
          else
            if note_cut and active_notes[ch] then
              active_notes[ch].end_time = row_time + note_cut
            end
          end
        end
      end
      
      for ch = 1, xm.num_channels do
        if active_notes[ch] then
          local an = active_notes[ch]
          if an.end_time > pattern_end_time then
            an.end_time = pattern_end_time
          end
          create_item_for_note(an, ch)
          active_notes[ch] = nil
        end
      end
      
      current_time = pattern_end_time
    end
  end
  
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Import XM as Empty Items: " .. xm.module_name, -1)
  
  return items_created
end

local function main()
  if not reaper then
    print("This script must be run in REAPER")
    return
  end
  
  local retval, filepath = reaper.GetUserFileNameForRead("", "Select XM File", "xm")
  if not retval then return end
  
  local xm = XMParser.new()
  local success, err = xm:parse(filepath)
  
  if not success then
    reaper.ShowMessageBox("Error: " .. err, "XM Import Error", 0)
    return
  end
  
  local info = string.format(
    "Module: %s\n" ..
    "Channels: %d\n" ..
    "Patterns: %d (Song length: %d)\n" ..
    "Instruments: %d\n" ..
    "Tempo: %d / BPM: %d\n\n" ..
    "Each note → empty item with:\n" ..
    "• Take name: note, instrument, volume\n" ..
    "• D_PITCH: semitones from C4\n" ..
    "• D_VOL: volume (0-1)\n" ..
    "• Item notes: full details\n" ..
    "• Color: by instrument\n\n" ..
    "Import?",
    xm.module_name,
    xm.num_channels,
    xm.num_patterns, xm.song_length,
    xm.num_instruments,
    xm.default_tempo, xm.default_bpm
  )
  
  if reaper.ShowMessageBox(info, "XM to Empty Items", 1) ~= 1 then
    return
  end
  
  local items_created = import_xm_to_reaper(xm)
  
  reaper.ShowMessageBox(
    string.format(
      "Import complete!\n\n" ..
      "• %d empty items created\n" ..
      "• %d channel tracks\n\n" ..
      items_created,
      xm.num_channels
    ),
    "Import Complete", 0)
end

main()
