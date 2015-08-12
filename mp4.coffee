Bits = require './bits'
EventEmitterModule = require './event_emitter'
Sequent = require 'sequent'
fs = require 'fs'
logger = require './logger'

formatDate = (date) ->
  date.toISOString()

TAG_CTOO = new Buffer([0xa9, 0x74, 0x6f, 0x6f]).toString 'utf8'
MIN_TIME_DIFF = 0.01  # seconds
READ_BUFFER_TIME = 3.0
QUEUE_BUFFER_TIME = 1.5

DEBUG = false

getCurrentTime = ->
  time = process.hrtime()
  return time[0] + time[1] / 1e9

class MP4File
  constructor: (filename) ->
    if filename?
      @open filename
    @isStopped = false

  open: (filename) ->
    @filename = filename
    if DEBUG
      startTime = process.hrtime()
    @fileBuf = fs.readFileSync filename  # up to 1GB
    @bits = new Bits @fileBuf
    if DEBUG
      diffTime = process.hrtime startTime
      console.log "took #{(diffTime[0] * 1e9 + diffTime[1]) / 1000000} ms to read"

  close: ->
    if not @isStopped
      @stop()
    @bits = null
    @emit 'close'
    return

  parse: ->
    if DEBUG
      startTime = process.hrtime()
    @boxes = []
    while @bits.has_more_data()
      box = Box.parse @bits, null  # null == root box
      if box instanceof MovieBox
        @moovBox = box
      else if box instanceof MediaDataBox
        @mdatBox = box
      @boxes.push box
    if DEBUG
      diffTime = process.hrtime startTime
      console.log "took #{(diffTime[0] * 1e9 + diffTime[1]) / 1000000} ms to parse"
      console.log "EOF"

    for child in @moovBox.children
      if child instanceof TrackBox  # trak
        tkhdBox = child.find 'tkhd'
        if tkhdBox.isAudioTrack
          @audioTrakBox = child
        else
          @videoTrakBox = child

    return

  getTree: ->
    if not @boxes?
      throw new Error "parse() must be called before dump"
    tree = { root: [] }
    for box in @boxes
      tree.root.push box.getTree()
    return tree

  dump: ->
    if not @boxes?
      throw new Error "parse() must be called before dump"
    for box in @boxes
      process.stdout.write box.dump 0, 2
    return

  getSPS: ->
    avcCBox = @videoTrakBox.find 'avcC'
    return avcCBox.sequenceParameterSets[0]

  getPPS: ->
    avcCBox = @videoTrakBox.find 'avcC'
    return avcCBox.pictureParameterSets[0]

  getAudioSpecificConfig: ->
    esdsBox = @audioTrakBox.find 'esds'
    return esdsBox.decoderConfigDescriptor.decoderSpecificInfo.specificInfo

  stop: ->
    logger.debug "[mp4:#{@filename}] stop"
    @isStopped = true

  play: ->
    @currentTime = 0
    @consumedAudioSamples = 0
    @consumedVideoSamples = 0
    @consumedAudioChunks = 0
    @consumedVideoChunks = 0
    startTime = process.hrtime()
    @numVideoSamples = @getNumVideoSamples()
    @numAudioSamples = @getNumAudioSamples()

    seq = new Sequent

    @bufferedAudioTime = 0
    @bufferedVideoTime = 0
    @queuedAudioTime = 0
    @queuedVideoTime = 0
    @currentPlayTime = 0
    @playStartTime = getCurrentTime()
    @bufferedAudioSamples = []
    @bufferedVideoSamples = []

    @isAudioEOF = false
    @isVideoEOF = false

    @bufferAudio =>
      # audio samples has been buffered
      seq.done()

    @bufferVideo =>
      # video samples has been buffered
      seq.done()

    seq.wait 2, =>
      # ready to play
      @startStreaming()

  checkAudioBuffer: ->
    timeDiff = @bufferedAudioTime - @currentPlayTime
    if timeDiff < READ_BUFFER_TIME
      # fill buffer
      if @readNextAudioChunk()
        @queueBufferedSamples()
      else
        if not @isAudioEOF
          @isAudioEOF = true
          @checkEOF()
    else
      @queueBufferedSamples()
    return

  checkVideoBuffer: ->
    timeDiff = @bufferedVideoTime - @currentPlayTime
    if timeDiff < READ_BUFFER_TIME
      if @readNextVideoChunk()
        @queueBufferedSamples()
      else
        if not @isVideoEOF
          @isVideoEOF = true
          @checkEOF()
    else
      @queueBufferedSamples()
    return

  startStreaming: ->
    @queueBufferedSamples()

  updateCurrentPlayTime: ->
    @currentPlayTime = getCurrentTime() - @playStartTime

  queueBufferedAudioSamples: ->
    audioSample = @bufferedAudioSamples.shift()
    if not audioSample?  # @bufferedAudioSamples is empty
      return
    timeDiff = audioSample.time - @currentPlayTime
    if timeDiff <= MIN_TIME_DIFF
      @emit 'audio_data', audioSample.data, audioSample.pts
      @updateCurrentPlayTime()
    else
      setTimeout =>
        @emit 'audio_data', audioSample.data, audioSample.pts
        @updateCurrentPlayTime()
        @checkAudioBuffer()
      , timeDiff * 1000
    @queuedAudioTime = audioSample.time
    if @queuedAudioTime - @currentPlayTime < QUEUE_BUFFER_TIME
      @queueBufferedSamples()

  queueBufferedVideoSamples: ->
    videoSample = @bufferedVideoSamples.shift()
    if not videoSample?  # read buffer is empty
      return
    timeDiff = videoSample.time - @currentPlayTime
    if timeDiff <= MIN_TIME_DIFF
      @emit 'video_data', videoSample.data, videoSample.pts
      @updateCurrentPlayTime()
    else
      setTimeout =>
        @emit 'video_data', videoSample.data, videoSample.pts
        @updateCurrentPlayTime()
        @checkVideoBuffer()
      , timeDiff * 1000
    @queuedVideoTime = videoSample.time
    if @queuedVideoTime - @currentPlayTime < QUEUE_BUFFER_TIME
      @queueBufferedSamples()

  queueBufferedSamples: ->
    if @isStopped
      return
    @queueBufferedAudioSamples()
    @queueBufferedVideoSamples()

  checkEOF: ->
    if @isAudioEOF and @isVideoEOF
      @close()

  bufferAudio: (callback) ->
    # TODO: Use async
    while @bufferedAudioTime < @currentPlayTime + READ_BUFFER_TIME
      if not @readNextAudioChunk()
        @isAudioEOF = true
        @checkEOF()
    callback?()

  bufferVideo: (callback) ->
    # TODO: Use async
    while @bufferedVideoTime < @currentPlayTime + READ_BUFFER_TIME
      if not @readNextVideoChunk()
        @isVideoEOF = true
        @checkEOF()
    callback?()

  getNumVideoSamples: ->
    sttsBox = @videoTrakBox.find 'stts'
    return sttsBox.getTotalSamples()

  getNumAudioSamples: ->
    sttsBox = @audioTrakBox.find 'stts'
    return sttsBox.getTotalSamples()

  parseH264Sample: (buf) ->
    # The format is defined in ISO 14496-15 5.2.3
    # <length><NAL unit> <length><NAL unit> ...

    avcCBox = @videoTrakBox.find 'avcC'
    lengthSize = avcCBox.lengthSizeMinusOne + 1
    bits = new Bits buf

    nalUnits = []

    while bits.has_more_data()
      length = bits.read_bits lengthSize * 8
      nalUnits.push bits.read_bytes(length)

    if bits.get_remaining_bits() isnt 0
      throw new Error "number of remaining bits is not zero: #{bits.get_remaining_bits()}"

    return nalUnits

  readChunk: (chunkNumber, sampleNumber, trakBox) ->
    sttsBox = trakBox.find 'stts'
    stscBox = trakBox.find 'stsc'
    numSamplesInChunk = stscBox.getNumSamplesInChunk chunkNumber
    stcoBox = trakBox.find 'stco'
    chunkOffset = stcoBox.getChunkOffset chunkNumber
    stszBox = trakBox.find 'stsz'
    sampleSizes = stszBox.getSampleSizes sampleNumber, numSamplesInChunk
    chunkLength = stszBox.getSampleSize sampleNumber, numSamplesInChunk
    cttsBox = trakBox.find 'ctts'
    samples = []
    sampleOffset = 0
    mdhdBox = trakBox.find('mdia').find('mdhd')
    for sampleSize, i in sampleSizes
      compositionTimeOffset = 0
      if cttsBox?
        compositionTimeOffset = cttsBox.getCompositionTimeOffset sampleNumber + i
      sampleTime = sttsBox.getDecodingTime sampleNumber + i
      compositionTime = sampleTime.time + compositionTimeOffset
      if mdhdBox.timescale isnt 90000
        pts = Math.round(compositionTime * 90000 / mdhdBox.timescale)
      else
        pts = compositionTime
      samples.push {
        pts: pts
        time: sampleTime.seconds
        data: @fileBuf[chunkOffset+sampleOffset...chunkOffset+sampleOffset+sampleSize]
      }
      sampleOffset += sampleSize

    return samples

  readNextVideoChunk: ->
    if @consumedVideoSamples >= @numVideoSamples
      return false
    nextChunkNumber = @consumedVideoChunks + 1
    nextSampleNumber = @consumedVideoSamples + 1

    samples = @readChunk nextChunkNumber, nextSampleNumber, @videoTrakBox

    numSamples = samples.length
    index = 0
    # The size of samples array may be altered in-place
    while index < samples.length
      nalUnits = @parseH264Sample samples[index].data
      if nalUnits.length >= 1
        pts = samples[index].pts
        time = samples[index].time

        samples[index].data = nalUnits[0]
        for nalUnit in nalUnits[1..]
          index++
          samples[index...index] =
            pts: pts
            time: time
            data: nalUnit
      index++

    @consumedVideoChunks++
    @consumedVideoSamples += numSamples
    @bufferedVideoTime = samples[samples.length-1].time
    @bufferedVideoSamples = @bufferedVideoSamples.concat samples

    return true

  parseAACSample: (buf) ->
    # nop

  readNextAudioChunk: ->
    if @consumedAudioSamples >= @numAudioSamples
      return false
    nextChunkNumber = @consumedAudioChunks + 1
    nextSampleNumber = @consumedAudioSamples + 1

    samples = @readChunk nextChunkNumber, nextSampleNumber, @audioTrakBox

#    for sample in samples
#      @parseAACSample sample.data

    @consumedAudioChunks++
    @consumedAudioSamples += samples.length
    @bufferedAudioTime = samples[samples.length-1].time
    @bufferedAudioSamples = @bufferedAudioSamples.concat samples

    return true

EventEmitterModule.mixin MP4File

class Box
  # time: seconds since midnight, Jan. 1, 1904 UTC
  @mp4TimeToDate: (time) ->
    return new Date(new Date('1904-01-01 00:00:00+0000').getTime() + time * 1000)

  getTree: ->
    obj =
      type: @typeStr
    if @children?
      obj.children = []
      for child in @children
        obj.children.push child.getTree()
    return obj

  dump: (depth=0, detailLevel=0) ->
    str = ''
    for i in [0...depth]
      str += '  '
    str += "#{@typeStr}"
    if detailLevel > 0
      detailString = @getDetails detailLevel
      if detailString?
        str += " (#{detailString})"
    str += "\n"
    if @children?
      for child in @children
        str += child.dump depth+1, detailLevel
    return str

  getDetails: (detailLevel) ->
    return null

  constructor: (info) ->
    for name, value of info
      @[name] = value
    if @data?
      @read @data

  readFullBoxHeader: (bits) ->
    @version = bits.read_byte()
    @flags = bits.read_bits 24
    return

  findParent: (typeStr) ->
    if @parent?
      if @parent.typeStr is typeStr
        return @parent
      else
        return @parent.findParent typeStr
    else
      return null

  find: (typeStr) ->
    if @typeStr is typeStr
      return this
    else
      if @children?
        for child in @children
          box = child.find typeStr
          if box?
            return box
      return null

  read: (buf) ->

  @readHeader: (bits, destObj) ->
    destObj.size = bits.read_uint32()
    destObj.type = bits.read_bytes 4
    destObj.typeStr = destObj.type.toString 'utf8'
    headerLen = 8
    if destObj.size is 1
      destObj.size = bits.read_bits 64  # TODO: might lose some precision
      headerLen += 8
    if destObj.typeStr is 'uuid'
      usertype = bits.read_bytes 16
      headerLen += 16

    if destObj.size > 0
      destObj.data = bits.read_bytes(destObj.size - headerLen)
    else
      destObj.data = bits.remaining_buffer()
      destObj.size = headerLen + destObj.data.length

    if destObj.typeStr is 'uuid'
      box.usertype = usertype

    return

  @readLanguageCode: (bits) ->
    return Box.readASCII(bits) + Box.readASCII(bits) + Box.readASCII(bits)

  @readASCII: (bits) ->
    diff = bits.read_bits 5
    return String.fromCharCode 0x60 + diff

  @parse: (bits, parent=null, cls) ->
    info = {}
    info.parent = parent
    @readHeader bits, info

    switch info.typeStr
      when 'ftyp'
        return new FileTypeBox info
      when 'moov'
        return new MovieBox info
      when 'mvhd'
        return new MovieHeaderBox info
      when 'mdat'
        return new MediaDataBox info
      when 'trak'
        return new TrackBox info
      when 'tkhd'
        return new TrackHeaderBox info
      when 'edts'
        return new EditBox info
      when 'elst'
        return new EditListBox info
      when 'mdia'
        return new MediaBox info
      when 'iods'
        return new ObjectDescriptorBox info
      when 'mdhd'
        return new MediaHeaderBox info
      when 'hdlr'
        return new HandlerBox info
      when 'minf'
        return new MediaInformationBox info
      when 'vmhd'
        return new VideoMediaHeaderBox info
      when 'dinf'
        return new DataInformationBox info
      when 'dref'
        return new DataReferenceBox info
      when 'url '
        return new DataEntryUrlBox info
      when 'urn '
        return new DataEntryUrnBox info
      when 'stbl'
        return new SampleTableBox info
      when 'stsd'
        return new SampleDescriptionBox info
      when 'stts'
        return new TimeToSampleBox info
      when 'stss'
        return new SyncSampleBox info
      when 'stsc'
        return new SampleToChunkBox info
      when 'stsz'
        return new SampleSizeBox info
      when 'stco'
        return new ChunkOffsetBox info
      when 'smhd'
        return new SoundMediaHeaderBox info
      when 'meta'
        return new MetaBox info
      when 'pitm'
        return new PrimaryItemBox info
      when 'iloc'
        return new ItemLocationBox info
      when 'ipro'
        return new ItemProtectionBox info
      when 'infe'
        return new ItemInfoEntry info
      when 'iinf'
        return new ItemInfoBox info
      when 'ilst'
        return new MetadataItemListBox info
      when 'gsst'
        return new GoogleGSSTBox info
      when 'gstd'
        return new GoogleGSTDBox info
      when 'gssd'
        return new GoogleGSSDBox info
      when 'gspu'
        return new GoogleGSPUBox info
      when 'gspm'
        return new GoogleGSPMBox info
      when 'gshh'
        return new GoogleGSHHBox info
      when 'udta'
        return new UserDataBox info
      when 'avc1'
        return new AVCSampleEntry info
      when 'avcC'
        return new AVCConfigurationBox info
      when 'btrt'
        return new MPEG4BitRateBox info
      when 'm4ds'
        return new MPEG4ExtensionDescriptorsBox info
      when 'mp4a'
        return new MP4AudioSampleEntry info
      when 'esds'
        return new ESDBox info
      when 'free'
        return new FreeSpaceBox info
      when 'ctts'
        return new CompositionOffsetBox info
      when TAG_CTOO
        return new CTOOBox info
      else
        if cls?
          return new cls info
        else
          console.log "warning: mp4: skipping unknown (not implemented) box type: #{info.typeStr} (0x#{info.type.toString('hex')})"
          return new Box info

class Container extends Box
  read: (buf) ->
    bits = new Bits buf
    @children = []
    while bits.has_more_data()
      box = Box.parse bits, this
      @children.push box
    return

#  getDetails: (detailLevel) ->
#    "Container"

# moov
class MovieBox extends Container

# stbl
class SampleTableBox extends Container

# dinf
class DataInformationBox extends Container

# udta
class UserDataBox extends Container

# minf
class MediaInformationBox extends Container

# mdia
class MediaBox extends Container

# edts
class EditBox extends Container

# trak
class TrackBox extends Container

# ftyp
class FileTypeBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @majorBrand = bits.read_uint32()
    @majorBrandStr = Bits.uintToString @majorBrand, 4
    @minorVersion = bits.read_uint32()
    @compatibleBrands = []
    while bits.has_more_data()
      brand = bits.read_bytes 4
      brandStr = brand.toString 'utf8'
      @compatibleBrands.push
        brand: brand
        brandStr: brandStr
    return

  getDetails: (detailLevel) ->
    "brand=#{@majorBrandStr} version=#{@minorVersion}"

  getTree: ->
    obj = super
    obj.brand = @majorBrandStr
    obj.version = @minorVersion
    return obj

# mvhd
class MovieHeaderBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    if @version is 1
      @creationTime = bits.read_bits 64  # TODO: loses precision
      @creationDate = Box.mp4TimeToDate @creationTime
      @modificationTime = bits.read_bits 64  # TODO: loses precision
      @modificationDate = Box.mp4TimeToDate @modificationTime
      @timescale = bits.read_uint32()
      @duration = bits.read_bits 64  # TODO: loses precision
      @durationSeconds = @duration / @timescale
    else  # @version is 0
      @creationTime = bits.read_bits 32  # TODO: loses precision
      @creationDate = Box.mp4TimeToDate @creationTime
      @modificationTime = bits.read_bits 32  # TODO: loses precision
      @modificationDate = Box.mp4TimeToDate @modificationTime
      @timescale = bits.read_uint32()
      @duration = bits.read_bits 32  # TODO: loses precision
      @durationSeconds = @duration / @timescale
    @rate = bits.read_int 32
    if @rate isnt 0x00010000  # 1.0
      console.log "Irregular rate: #{@rate}"
    @volume = bits.read_int 16
    if @volume isnt 0x0100  # full volume
      console.log "Irregular volume: #{@volume}"
    reserved = bits.read_bits 16
    if reserved isnt 0
      throw new Error "reserved bits are not all zero: #{reserved}"
    reservedInt1 = bits.read_int 32
    if reservedInt1 isnt 0
      throw new Error "reserved int(32) (1) is not zero: #{reservedInt1}"
    reservedInt2 = bits.read_int 32
    if reservedInt2 isnt 0
      throw new Error "reserved int(32) (2) is not zero: #{reservedInt2}"
    bits.skip_bytes 4 * 9  # Unity matrix
    bits.skip_bytes 4 * 6  # pre_defined
    @nextTrackID = bits.read_uint32()

    if bits.has_more_data()
      throw new Error "mvhd box has more data"

  getDetails: (detailLevel) ->
    "created=#{formatDate @creationDate} modified=#{formatDate @modificationDate} timescale=#{@timescale} durationSeconds=#{@durationSeconds}"

  getTree: ->
    obj = super
    obj.creationDate = @creationDate
    obj.modificationDate = @modificationDate
    obj.timescale = @timescale
    obj.duration = @duration
    obj.durationSeconds = @durationSeconds
    return obj

# Object Descriptor Box: contains an Object Descriptor or an Initial Object Descriptor
# (iods)
# Defined in ISO 14496-14
class ObjectDescriptorBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits
    return

# Track header box: specifies the characteristics of a single track (tkhd)
class TrackHeaderBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    if @version is 1
      @creationTime = bits.read_bits 64  # TODO: loses precision
      @creationDate = Box.mp4TimeToDate @creationTime
      @modificationTime = bits.read_bits 64  # TODO: loses precision
      @modificationDate = Box.mp4TimeToDate @modificationTime
      @trackID = bits.read_uint32()
      reserved = bits.read_uint32()
      if reserved isnt 0
        throw new Error "tkhd: reserved bits are not zero: #{reserved}"
      @duration = bits.read_bits 64  # TODO: loses precision
    else  # @version is 0
      @creationTime = bits.read_bits 32  # TODO: loses precision
      @creationDate = Box.mp4TimeToDate @creationTime
      @modificationTime = bits.read_bits 32  # TODO: loses precision
      @modificationDate = Box.mp4TimeToDate @modificationTime
      @trackID = bits.read_uint32()
      reserved = bits.read_uint32()
      if reserved isnt 0
        throw new Error "tkhd: reserved bits are not zero: #{reserved}"
      @duration = bits.read_bits 32  # TODO: loses precision
    reserved = bits.read_bits 64
    if reserved isnt 0
      throw new Error "tkhd: reserved bits are not zero: #{reserved}"
    @layer = bits.read_int 16
    if @layer isnt 0
      console.log "layer is not 0: #{@layer}"
    @alternateGroup = bits.read_int 16
#    if @alternateGroup isnt 0
#      console.log "tkhd: alternate_group is not 0: #{@alternateGroup}"
    @volume = bits.read_int 16
    if @volume is 0x0100
      @isAudioTrack = true
    else
      @isAudioTrack = false
    reserved = bits.read_bits 16
    if reserved isnt 0
      throw new Error "tkhd: reserved bits are not zero: #{reserved}"
    bits.skip_bytes 4 * 9
    @width = bits.read_uint32() / 65536  # fixed-point 16.16 value
    @height = bits.read_uint32() / 65536  # fixed-point 16.16 value

    if bits.has_more_data()
      throw new Error "tkhd box has more data"

  getDetails: (detailLevel) ->
    str = "created=#{formatDate @creationDate} modified=#{formatDate @modificationDate}"
    if @isAudioTrack
      str += " audio"
    else
      str += " video; width=#{@width} height=#{@height}"
    return str

  getTree: ->
    obj = super
    obj.creationDate = @creationDate
    obj.modificationDate = @modificationDate
    obj.isAudioTrack = @isAudioTrack
    obj.width = @width
    obj.height = @height
    return obj

# elst
# Edit list box: explicit timeline map
class EditListBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    # moov
    #   mvhd <- find target
    #   iods
    #   trak
    #     tkhd
    #     edts
    #       elst <- self
    mvhdBox = @findParent('moov').find('mvhd')

    entryCount = bits.read_uint32()
    @entries = []
    for i in [1..entryCount]
      if @version is 1
        segmentDuration = bits.read_bits 64  # TODO: loses precision
        mediaTime = bits.read_int 64
      else  # @version is 0
        segmentDuration = bits.read_bits 32
        mediaTime = bits.read_int 32
      mediaRateInteger = bits.read_int 16
      mediaRateFraction = bits.read_int 16
      if mediaRateFraction isnt 0
        console.log "media_rate_fraction is not 0: #{mediaRateFraction}"
      @entries.push
        segmentDuration: segmentDuration
        segmentDurationSeconds: segmentDuration / mvhdBox.timescale
        mediaTime: mediaTime
        mediaRate: mediaRateInteger + mediaRateFraction / 65536 # TODO: Is this correct?

    if bits.has_more_data()
      throw new Error "elst box has more data"

  getDetails: (detailLevel) ->
    @entries.map((entry) ->
      "segmentDurationSeconds=#{entry.segmentDurationSeconds} mediaTime=#{entry.mediaTime} mediaRate=#{entry.mediaRate}"
    ).join(',')

  getTree: ->
    obj = super
    obj.entries = @entries
    return obj

# Media Header Box (mdhd): declares overall information
# Container: Media Box ('mdia')
# Defined in ISO 14496-12
class MediaHeaderBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    if @version is 1
      @creationTime = bits.read_bits 64  # TODO: loses precision
      @creationDate = Box.mp4TimeToDate @creationTime
      @modificationTime = bits.read_bits 64  # TODO: loses precision
      @modificationDate = Box.mp4TimeToDate @modificationTime
      @timescale = bits.read_uint32()
      @duration = bits.read_bits 64  # TODO: loses precision
    else  # @version is 0
      @creationTime = bits.read_bits 32
      @creationDate = Box.mp4TimeToDate @creationTime
      @modificationTime = bits.read_bits 32
      @modificationDate = Box.mp4TimeToDate @modificationTime
      @timescale = bits.read_uint32()
      @duration = bits.read_uint32()
    @durationSeconds = @duration / @timescale
    pad = bits.read_bit()
    if pad isnt 0
      throw new Error "mdhd: pad is not 0: #{pad}"
    @language = Box.readLanguageCode bits
    pre_defined = bits.read_bits 16
    if pre_defined isnt 0
      throw new Error "mdhd: pre_defined is not 0: #{pre_defined}"

  getDetails: (detailLevel) ->
    "created=#{formatDate @creationDate} modified=#{formatDate @modificationDate} timescale=#{@timescale} durationSeconds=#{@durationSeconds} lang=#{@language}"

  getTree: ->
    obj = super
    obj.creationDate = @creationDate
    obj.modificationDate = @modificationDate
    obj.timescale = @timescale
    obj.duration = @duration
    obj.durationSeconds = @durationSeconds
    obj.language = @language
    return obj

# Handler Reference Box (hdlr): declares the nature of the media in a track
# Container: Media Box ('mdia') or Meta Box ('meta')
# Defined in ISO 14496-12
class HandlerBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    pre_defined = bits.read_bits 32
    if pre_defined isnt 0
      throw new Error "hdlr: pre_defined is not 0 (got #{pre_defined})"
    @handlerType = bits.read_bytes(4).toString 'utf8'
    # vide: Video track
    # soun: Audio track
    # hint: Hint track
    bits.skip_bytes 4 * 3  # reserved 0 bits (may not be all zero if handlerType is
                           # none of the above)
    @name = bits.get_string()
    return

  getDetails: (detailLevel) ->
    "handlerType=#{@handlerType} name=#{@name}"

  getTree: ->
    obj = super
    obj.handlerType = @handlerType
    obj.name = @name
    return obj

# Video Media Header Box (vmhd): general presentation information
class VideoMediaHeaderBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @graphicsmode = bits.read_bits 16
    if @graphicsmode isnt 0
      console.warn "warning: vmhd: non-standard graphicsmode: #{@graphicsmode}"
    @opcolor = {}
    @opcolor.red = bits.read_bits 16
    @opcolor.green = bits.read_bits 16
    @opcolor.blue = bits.read_bits 16

#  getDetails: (detailLevel) ->
#    "graphicsMode=#{@graphicsmode} opColor=0x#{Bits.zeropad 2, @opcolor.red.toString 16}#{Bits.zeropad 2, @opcolor.green.toString 16}#{Bits.zeropad 2, @opcolor.blue.toString 16}"

# Data Reference Box (dref): table of data references that declare
#                            locations of the media data
class DataReferenceBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    entry_count = bits.read_uint32()
    @children = []
    for i in [1..entry_count]
      @children.push Box.parse bits, this
    return

# "url "
class DataEntryUrlBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    if bits.has_more_data()
      @location = bits.get_string()
    else
      @location = null
    return

  getDetails: (detailLevel) ->
    if @location?
      "location=#{@location}"
    else
      "empty location value"

  getTree: ->
    obj = super
    obj.location = @location
    return obj

# "urn "
class DataEntryUrnBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    if bits.has_more_data()
      @name = bits.get_string()
    else
      @name = null
    if bits.has_more_data()
      @location = bits.get_string()
    else
      @location = null
    return

# Sample Description Box (stsd): coding type and any initialization information
# Defined in ISO 14496-12
class SampleDescriptionBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    # moov
    #   mvhd
    #   iods
    #   trak
    #     tkhd
    #     edts
    #       elst
    #     mdia
    #       mdhd
    #       hdlr <- find target
    #       minf
    #         vmhd
    #         dinf
    #           dref
    #             url 
    #         stbl
    #           stsd <- self
    #             stts
    handlerRefBox = @findParent('mdia').find('hdlr')
    handlerType = handlerRefBox.handlerType

    entry_count = bits.read_uint32()
    @children = []
    for i in [1..entry_count]
      switch handlerType
        when 'soun'  # for audio tracks
          @children.push Box.parse bits, this, AudioSampleEntry
        when 'vide'  # for video tracks
          @children.push Box.parse bits, this, VisualSampleEntry
        when 'hint'  # hint track
          @children.push Box.parse bits, this, HintSampleEntry
        else
          console.log "warning: mp4: ignoring a sample entry for unknown handlerType: #{handlerType}"
    return

class HintSampleEntry extends Box
  read: (buf) ->
    bits = new Bits buf
    # SampleEntry
    reserved = bits.read_bits 8 * 6
    if reserved isnt 0
      throw new Error "VisualSampleEntry: reserved bits are not 0: #{reserved}"
    @dataReferenceIndex = bits.read_bits 16

    # unsigned int(8) data []

    return

class AudioSampleEntry extends Box
  read: (buf) ->
    bits = new Bits buf
    # SampleEntry
    reserved = bits.read_bits 8 * 6
    if reserved isnt 0
      throw new Error "AudioSampleEntry: reserved bits are not 0: #{reserved}"
    @dataReferenceIndex = bits.read_bits 16

    reserved = bits.read_bytes_sum 4 * 2
    if reserved isnt 0
      throw new Error "AudioSampleEntry: reserved-1 bits are not 0: #{reserved}"

    @channelCount = bits.read_bits 16
    if @channelCount isnt 2
      throw new Error "AudioSampleEntry: channelCount is not 2: #{@channelCount}"

    @sampleSize = bits.read_bits 16
    if @sampleSize isnt 16
      throw new Error "AudioSampleEntry: sampleSize is not 16: #{@sampleSize}"

    pre_defined = bits.read_bits 16
    if pre_defined isnt 0
      throw new Error "AudioSampleEntry: pre_defined is not 0: #{pre_defined}"

    reserved = bits.read_bits 16
    if reserved isnt 0
      throw new Error "AudioSampleEntry: reserved-2 bits are not 0: #{reserved}"

    # moov
    #   mvhd
    #   iods
    #   trak
    #     tkhd
    #     edts
    #       elst
    #     mdia
    #       mdhd <- find target
    #       hdlr
    #       minf
    #         vmhd
    #         dinf
    #           dref
    #             url 
    #         stbl
    #           stsd <- self
    #             stts
    mdhdBox = @findParent('mdia').find('mdhd')

    @sampleRate = bits.read_uint32()
    if @sampleRate isnt mdhdBox.timescale * Math.pow(2, 16)  # "<< 16" may lead to int32 overflow
      throw new Error "AudioSampleEntry: illegal sampleRate: #{@sampleRate} (should be #{mdhdBox.timescale << 16})"

    @remaining_buf = bits.remaining_buffer()
    return

class VisualSampleEntry extends Box
  read: (buf) ->
    bits = new Bits buf
    # SampleEntry
    reserved = bits.read_bits 8 * 6
    if reserved isnt 0
      throw new Error "VisualSampleEntry: reserved bits are not 0: #{reserved}"
    @dataReferenceIndex = bits.read_bits 16

    # VisualSampleEntry
    pre_defined = bits.read_bits 16
    if pre_defined isnt 0
      throw new Error "VisualSampleEntry: pre_defined bits are not 0: #{pre_defined}"
    reserved = bits.read_bits 16
    if reserved isnt 0
      throw new Error "VisualSampleEntry: reserved bits are not 0: #{reserved}"
    pre_defined = bits.read_bytes_sum 4 * 3
    if pre_defined isnt 0
      throw new Error "VisualSampleEntry: pre_defined is not 0: #{pre_defined}"
    @width = bits.read_bits 16
    @height = bits.read_bits 16
    @horizontalResolution = bits.read_uint32()
    if @horizontalResolution isnt 0x00480000  # 72 dpi
      throw new Error "VisualSampleEntry: horizontalResolution is not 0x00480000: #{@horizontalResolution}"
    @verticalResolution = bits.read_uint32()
    if @verticalResolution isnt 0x00480000  # 72 dpi
      throw new Error "VisualSampleEntry: verticalResolution is not 0x00480000: #{@verticalResolution}"
    reserved = bits.read_uint32()
    if reserved isnt 0
      throw new Error "VisualSampleEntry: reserved bits are not 0: #{reserved}"
    @frameCount = bits.read_bits 16
    if @frameCount isnt 1
      throw new Error "VisualSampleEntry: frameCount is not 1: #{@frameCount}"

    # compressor name: 32 bytes
    compressorNameBytes = bits.read_byte()
    if compressorNameBytes > 0
      @compressorName = bits.read_bytes(compressorNameBytes).toString 'utf8'
    else
      @compressorName = null
    paddingLen = 32 - 1 - compressorNameBytes
    if paddingLen > 0
      bits.skip_bytes paddingLen

    @depth = bits.read_bits 16
    if @depth isnt 0x0018
      throw new Error "VisualSampleEntry: depth is not 0x0018: #{@depth}"
    pre_defined = bits.read_int 16
    if pre_defined isnt -1
      throw new Error "VisualSampleEntry: pre_defined is not -1: #{pre_defined}"

    @remaining_buf = bits.remaining_buffer()
    return

# stts
# Defined in ISO 14496-12
class TimeToSampleBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @entryCount = bits.read_uint32()
    @entries = []
    for i in [0...@entryCount]
      # number of consecutive samples that have the given duration
      sampleCount = bits.read_uint32()
      # delta of these samples in the time-scale of the media
      sampleDelta = bits.read_uint32()
      if sampleDelta < 0
        throw new Error "stts: negative sampleDelta is not allowed: #{sampleDelta}"
      @entries.push
        sampleCount: sampleCount
        sampleDelta: sampleDelta
    return

  getTotalSamples: ->
    samples = 0
    for entry in @entries
      samples += entry.sampleCount
    return samples

  # Returns the total length of this media in seconds
  getTotalLength: ->
    # mdia
    #   mdhd <- find target
    #   hdlr
    #   minf
    #     vmhd
    #     dinf
    #       dref
    #         url
    #     stbl
    #       stsd
    #         avc1
    #           avcC
    #           btrt
    #       stts <- self
    mdhdBox = @findParent('mdia').find('mdhd')

    time = 0
    for entry in @entries
      time += entry.sampleDelta * entry.sampleCount
    return time / mdhdBox.timescale

  # Returns a decoding time for the given sample number.
  # The sample number starts at 1.
  getDecodingTime: (sampleNumber) ->
    mdhdBox = @findParent('mdia').find('mdhd')

    sampleNumber--
    time = 0
    for entry in @entries
      if sampleNumber > entry.sampleCount
        time += entry.sampleDelta * entry.sampleCount
        sampleNumber -= entry.sampleCount
      else
        time += entry.sampleDelta * sampleNumber
        break
    return {
      time: time
      seconds: time / mdhdBox.timescale
    }

  getDetails: (detailLevel) ->
    str = "entryCount=#{@entryCount}"
    if detailLevel >= 2
      str += ' ' + @entries.map((entry) ->
        "sampleCount=#{entry.sampleCount} sampleDelta=#{entry.sampleDelta}"
      ).join(',')
    return str

  getTree: ->
    obj = super
    obj.entries = @entries
    return obj

# stss: random access points
# If stss is not present, every sample is a random access point.
class SyncSampleBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @entryCount = bits.read_uint32()
    @sampleNumbers = []
    lastSampleNumber = -1
    for i in [0...@entryCount]
      sampleNumber = bits.read_uint32()
      if sampleNumber < lastSampleNumber
        throw new Error "stss: sample number must be in increasing order: #{sampleNumber} < #{lastSampleNumber}"
      lastSampleNumber = sampleNumber
      @sampleNumbers.push sampleNumber
    return

  getDetails: (detailLevel) ->
    if detailLevel >= 2
      "sampleNumbers=#{@sampleNumbers.join ','}"
    else
      "entryCount=#{@entryCount}"

  getTree: ->
    obj = super
    obj.sampleNumbers = @sampleNumbers
    return obj

# stsc: number of samples for each chunk
class SampleToChunkBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @entryCount = bits.read_uint32()
    @entries = []
    for i in [0...@entryCount]
      firstChunk = bits.read_uint32()
      samplesPerChunk = bits.read_uint32()
      sampleDescriptionIndex = bits.read_uint32()
      @entries.push
        firstChunk: firstChunk
        samplesPerChunk: samplesPerChunk
        sampleDescriptionIndex: sampleDescriptionIndex

    # Determine the number of chunks of each entry
    endIndex = @entries.length - 1
    for i in [0...endIndex]
      if i is endIndex
        break
      @entries[i].numChunks = @entries[i+1].firstChunk - @entries[i].firstChunk

    return

  getNumSamplesExceptLastChunk: ->
    samples = 0
    for entry in @entries
      if entry.numChunks?
        samples += entry.samplesPerChunk * entry.numChunks
    return samples

  getNumSamplesInChunk: (chunk) ->
    for entry in @entries
      if not entry.numChunks?
        # TOOD: too heavy
        sttsBox = @findParent('stbl').find 'stts'
        return entry.samplesPerChunk
      if chunk < entry.firstChunk + entry.numChunks
        return entry.samplesPerChunk
    throw new Error "Chunk not found: #{chunk}"

  findChunk: (sampleNumber) ->
    for entry in @entries
      if not entry.numChunks?
        return entry.firstChunk + Math.floor((sampleNumber-1) / entry.samplesPerChunk)
      if sampleNumber <= entry.samplesPerChunk * entry.numChunks
        return entry.firstChunk + Math.floor((sampleNumber-1) / entry.samplesPerChunk)
      sampleNumber -= entry.samplesPerChunk * entry.numChunks
    throw new Error "Chunk for sample number #{sampleNumber} is not found"

  getDetails: (detailLevel) ->
    if detailLevel >= 2
      @entries.map((entry) ->
        "firstChunk=#{entry.firstChunk} samplesPerChunk=#{entry.samplesPerChunk} sampleDescriptionIndex=#{entry.sampleDescriptionIndex}"
      ).join(', ')
    else
      "entryCount=#{@entryCount}"

  getTree: ->
    obj = super
    obj.entries = @entries
    return obj

# stsz: sample sizes
class SampleSizeBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    # Default sample size
    # 0: samples have different sizes
    @sampleSize = bits.read_uint32()

    # Number of samples in the track
    @sampleCount = bits.read_uint32()
    if @sampleSize is 0
      @entrySizes = []
      for i in [1..@sampleCount]
        @entrySizes.push bits.read_uint32()
    return

  getSampleSizes: (sampleNumber, len=1) ->
    sizes = []
    if @sampleSize isnt 0
      for i in [len...0]
        sizes.push @sampleSize
    else
      for i in [len...0]
        sizes.push @entrySizes[sampleNumber - 1]
        sampleNumber++
    return sizes

  # Returns the sample size for the given sample number
  getSampleSize: (sampleNumber, len=1) ->
    if @sampleSize isnt 0  # all samples are the same size
      return @sampleSize * len
    else  # the samples have different sizes
      totalLength = 0
      for i in [len...0]
        if sampleNumber > @entrySizes.length
          throw new Error "Sample number is out of range: #{sampleNumber} > #{@entrySizes.length}"
        totalLength += @entrySizes[sampleNumber - 1]  # TODO: Is -1 correct?
        sampleNumber++
      return totalLength

  getDetails: (detailLevel) ->
    str = "sampleSize=#{@sampleSize} sampleCount=#{@sampleCount}"
    if @entrySizes?
      if detailLevel >= 2
        str += " entrySizes=#{@entrySizes.join ','}"
      else
        str += " num_entrySizes=#{@entrySizes.length}"
    return str

  getTree: ->
    obj = super
    obj.sampleSize = @sampleSize
    obj.sampleCount = @sampleCount
    if @entrySizes?
      obj.entrySizes = @entrySizes
    return obj

# stco: chunk offsets relative to the beginning of the file
class ChunkOffsetBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @entryCount = bits.read_uint32()
    @chunkOffsets = []
    for i in [1..@entryCount]
      @chunkOffsets.push bits.read_uint32()
    return

  # Returns a position of the chunk relative to the beginning of the file
  getChunkOffset: (chunkNumber) ->
    if (chunkNumber <= 0) or (chunkNumber > @chunkOffsets.length)
      throw new Error "Chunk number of out of range: #{chunkNumber}"
    return @chunkOffsets[chunkNumber - 1]

  getDetails: (detailLevel) ->
    if detailLevel >= 2
      "chunkOffsets=#{@chunkOffsets.join ','}"
    else
      "entryCount=#{@entryCount}"

  getTree: ->
    obj = super
    obj.chunkOffsets = @chunkOffsets
    return obj

# smhd
class SoundMediaHeaderBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @balance = bits.read_bits 16
    if @balance isnt 0
      throw new Error "smhd: balance is not 0: #{@balance}"

    reserved = bits.read_bits 16
    if reserved isnt 0
      throw new Error "smhd: reserved bits are not 0: #{reserved}"

    return

# meta: descriptive or annotative metadata
class MetaBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @children = []
    while bits.has_more_data()
      box = Box.parse bits, this
      @children.push box
    return

# pitm: one of the referenced items
class PrimaryItemBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @itemID = bits.read_bits 16
    return

# iloc
class ItemLocationBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @offsetSize = bits.read_bits 4
    @lengthSize = bits.read_bits 4
    @baseOffsetSize = bits.read_bits 4
    @reserved = bits.read_bits 4
    @itemCount = bits.read_bits 16
    @items = []
    for i in [0...@itemCount]
      itemID = bits.read_bits 16
      dataReferenceIndex = bits.read_bits 16
      baseOffset = bits.read_bits @baseOffsetSize * 8
      extentCount = bits.read_bits 16
      extents = []
      for j in [0...extentCount]
        extentOffset = bits.read_bits @offsetSize * 8
        extentLength = bits.read_bits @lengthSize * 8
        extents.push
          extentOffset: extentOffset
          extentLength: extentLength
      @items.push
        itemID: itemID
        dataReferenceIndex: dataReferenceIndex
        baseOffset: baseOffset
        extentCount: extentCount
        extents: extents
    return

# ipro: an array of item protection information
class ItemProtectionBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @protectionCount = bits.read_bits 16

    @children = []
    for i in [1..@protectionCount]
      box = Box.parse bits, this
      @children.push box
    return

# infe: extra information about selected items
class ItemInfoEntry extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @itemID = bits.read_bits 16
    @itemProtectionIndex = bits.read_bits 16
    @itemName = bits.get_string()
    @contentType = bits.get_string()
    if bits.has_more_data()
      @contentEncoding = bits.get_string()
    return

# iinf: extra information about selected items
class ItemInfoBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @entryCount = bits.read_bits 16

    @children = []
    for i in [1..@entryCount]
      box = Box.parse bits, this
      @children.push box
    return

# ilst: list of actual metadata values
class MetadataItemListBox extends Container

class GenericDataBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @length = bits.read_uint32()
    @name = bits.read_bytes(4).toString 'utf8'
    @entryCount = bits.read_uint32()
    zeroBytes = bits.read_bytes_sum 4
    if zeroBytes isnt 0
      console.log "warning: mp4: zeroBytes are not all zeros (got #{zeroBytes})"
    @value = bits.read_bytes(@length - 16)
    nullPos = @value.indexOf 0x00
    if nullPos is 0
      @valueStr = null
    else if nullPos isnt -1
      @valueStr = @value[0...nullPos].toString 'utf8'
    else
      @valueStr = @value.toString 'utf8'
    return

  getDetails: (detailLevel) ->
    return "#{@name}=#{@valueStr}"

  getTree: ->
    obj = super
    obj.data = @valueStr
    return obj

# gsst: unknown
class GoogleGSSTBox extends GenericDataBox

# gstd: unknown
class GoogleGSTDBox extends GenericDataBox

# gssd: unknown
class GoogleGSSDBox extends GenericDataBox

# gspu: unknown
class GoogleGSPUBox extends GenericDataBox

# gspm: unknown
class GoogleGSPMBox extends GenericDataBox

# gshh: unknown
class GoogleGSHHBox extends GenericDataBox

# Media Data Box (mdat): audio/video frames
# Defined in ISO 14496-12
class MediaDataBox extends Box
  read: (buf) ->
    # We will not parse the raw media stream

# avc1
# Defined in ISO 14496-15
class AVCSampleEntry extends VisualSampleEntry
  read: (buf) ->
    super buf
    bits = new Bits @remaining_buf
    @children = []
    @children.push Box.parse bits, this, AVCConfigurationBox
    if bits.has_more_data()
      @children.push Box.parse bits, this, MPEG4BitRateBox
    if bits.has_more_data()
      @children.push Box.parse bits, this, MPEG4ExtensionDescriptorsBox
    return

# btrt
# Defined in ISO 14496-15
class MPEG4BitRateBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @bufferSizeDB = bits.read_uint32()
    @maxBitrate = bits.read_uint32()
    @avgBitrate = bits.read_uint32()

  getDetails: (detailLevel) ->
    "bufferSizeDB=#{@bufferSizeDB} maxBitrate=#{@maxBitrate} avgBitrate=#{@avgBitrate}"

  getTree: ->
    obj = super
    obj.bufferSizeDB = @bufferSizeDB
    obj.maxBitrate = @maxBitrate
    obj.avgBitrate = @avgBitrate
    return obj

# m4ds
# Defined in ISO 14496-15
class MPEG4ExtensionDescriptorsBox
  read: (buf) ->
    # TODO: implement this?

# avcC
# Defined in ISO 14496-15
class AVCConfigurationBox extends Box
  read: (buf) ->
    bits = new Bits buf

    # AVCDecoderConfigurationRecord
    @configurationVersion = bits.read_byte()
    if @configurationVersion isnt 1
      throw new "mp4: avcC: unknown configurationVersion: #{@configurationVersion}"
    @AVCProfileIndication = bits.read_byte()
    @profileCompatibility = bits.read_byte()
    @AVCLevelIndication = bits.read_byte()
    reserved = bits.read_bits 6
#    if reserved isnt 0b111111  # XXX: not always 0b111111?
#      throw new Error "AVCConfigurationBox: reserved-1 is not #{0b111111} (got #{reserved})"
    @lengthSizeMinusOne = bits.read_bits 2
    reserved = bits.read_bits 3
#    if reserved isnt 0b111  # XXX: not always 0b111?
#      throw new Error "AVCConfigurationBox: reserved-2 is not #{0b111} (got #{reserved})"

    # SPS
    @numOfSequenceParameterSets = bits.read_bits 5
    @sequenceParameterSets = []
    for i in [0...@numOfSequenceParameterSets]
      sequenceParameterSetLength = bits.read_bits 16
      @sequenceParameterSets.push bits.read_bytes sequenceParameterSetLength

    # PPS
    @numOfPictureParameterSets = bits.read_byte()
    @pictureParameterSets = []
    for i in [0...@numOfPictureParameterSets]
      pictureParameterSetLength = bits.read_bits 16
      @pictureParameterSets.push bits.read_bytes pictureParameterSetLength

    return

  getDetails: (detailLevel) ->
    'sps=' + @sequenceParameterSets.map((sps) ->
      "0x#{sps.toString 'hex'}"
    ).join(',') + ' pps=' + @pictureParameterSets.map((pps) ->
      "0x#{pps.toString 'hex'}"
    ).join(',')

  getTree: ->
    obj = super
    obj.sps = @sequenceParameterSets.map((sps) -> [sps...])
    obj.pps = @pictureParameterSets.map((pps) -> [pps...])
    return obj

# esds
class ESDBox extends Box
  readDecoderConfigDescriptor: (bits) ->
    info = {}
    info.tag = bits.read_byte()
    if info.tag isnt 0x04  # 0x04 == DecoderConfigDescrTag
      throw new Error "ESDBox: DecoderConfigDescrTag is not 4 (got #{info.tag})"
    info.length = @readDescriptorLength bits
    info.objectProfileIndication = bits.read_byte()
    info.streamType = bits.read_bits 6
    info.upStream = bits.read_bit()
    reserved = bits.read_bit()
    if reserved isnt 1
      throw new Error "ESDBox: DecoderConfigDescriptor: reserved bit is not 1 (got #{reserved})"
    info.bufferSizeDB = bits.read_bits 24
    info.maxBitrate = bits.read_uint32()
    info.avgBitrate = bits.read_uint32()
    info.decoderSpecificInfo = @readDecoderSpecificInfo bits
    return info

  readDecoderSpecificInfo: (bits) ->
    info = {}
    info.tag = bits.read_byte()
    if info.tag isnt 0x05  # 0x05 == DecSpecificInfoTag
      throw new Error "ESDBox: DecSpecificInfoTag is not 5 (got #{info.tag})"
    info.length = @readDescriptorLength bits
    info.specificInfo = bits.read_bytes info.length
    return info

  readSLConfigDescriptor: (bits) ->
    info = {}
    info.tag = bits.read_byte()
    if info.tag isnt 0x06  # 0x06 == SLConfigDescrTag
      throw new Error "ESDBox: SLConfigDescrTag is not 6 (got #{info.tag})"
    info.length = @readDescriptorLength bits
    info.predefined = bits.read_byte()
    if info.predefined is 0
      info.useAccessUnitStartFlag = bits.read_bit()
      info.useAccessUnitEndFlag = bits.read_bit()
      info.useRandomAccessPointFlag = bits.read_bit()
      info.hasRandomAccessUnitsOnlyFlag = bits.read_bit()
      info.usePaddingFlag = bits.read_bit()
      info.useTimeStampsFlag = bits.read_bit()
      info.useIdleFlag = bits.read_bit()
      info.durationFlag = bits.read_bit()
      info.timeStampResolution = bits.read_uint32()
      info.ocrResolution = bits.read_uint32()
      info.timeStampLength = bits.read_byte()
      if info.timeStampLength > 64
        throw new Error "ESDBox: SLConfigDescriptor: timeStampLength must be <= 64 (got #{info.timeStampLength})"
      info.ocrLength = bits.read_byte()
      if info.ocrLength > 64
        throw new Error "ESDBox: SLConfigDescriptor: ocrLength must be <= 64 (got #{info.ocrLength})"
      info.auLength = bits.read_byte()
      if info.auLength > 32
        throw new Error "ESDBox: SLConfigDescriptor: auLength must be <= 64 (got #{info.auLength})"
      info.instantBitrateLength = bits.read_byte()
      info.degradationPriorityLength = bits.read_bits 4
      info.auSeqNumLength = bits.read_bits 5
      if info.auSeqNumLength > 16
        throw new Error "ESDBox: SLConfigDescriptor: auSeqNumLength must be <= 16 (got #{info.auSeqNumLength})"
      info.packetSeqNumLength = bits.read_bits 5
      if info.packetSeqNumLength > 16
        throw new Error "ESDBox: SLConfigDescriptor: packetSeqNumLength must be <= 16 (got #{info.packetSeqNumLength})"
      reserved = bits.read_bits 2
      if reserved isnt 0b11
        throw new Error "ESDBox: SLConfigDescriptor: reserved bits value is not #{0b11} (got #{reserved})"

      if info.durationFlag is 1
        info.timeScale = bits.read_uint32()
        info.accessUnitDuration = bits.read_bits 16
        info.compositionUnitDuration = bits.read_bits 16
      if info.useTimeStampsFlag is 0
        info.startDecodingTimeStamp = bits.read_bits info.timeStampLength
        info.startCompositionTimeStamp = bits.read_bits info.timeStamplength
    return info

  readDescriptorLength: (bits) ->
    len = bits.read_byte()
    # TODO: Is this correct?
    if len >= 0x80
      len = ((len & 0x7f) << 21) |
        ((bits.read_byte() & 0x7f) << 14) |
        ((bits.read_byte() & 0x7f) << 7) |
        bits.read_byte()
    return len

  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    # ES_Descriptor (defined in ISO 14496-1)
    @tag = bits.read_byte()
    if @tag isnt 0x03  # 0x03 == ES_DescrTag
      throw new Error "ESDBox: tag is not #{0x03} (got #{@tag})"
    @length = @readDescriptorLength bits
    @ES_ID = bits.read_bits 16
    @streamDependenceFlag = bits.read_bit()
    @urlFlag = bits.read_bit()
    @ocrStreamFlag = bits.read_bit()
    @streamPriority = bits.read_bits 5
    if @streamDependenceFlag is 1
      @depenedsOnES_ID = bits.read_bits 16
    if @urlFlag is 1
      @urlLength = bits.read_byte()
      @urlString = bits.read_bytes(@urlLength)
    if @ocrStreamFlag is 1
      @ocrES_ID = bits.read_bits 16

    @decoderConfigDescriptor = @readDecoderConfigDescriptor bits

    # TODO: if ODProfileLevelIndication is 0x01

    @slConfigDescriptor = @readSLConfigDescriptor bits

    # TODO:
    # IPI_DescPointer
    # IP_IdentificationDataSet
    # IPMP_DescriptorPointer
    # LanguageDescriptor
    # QoS_Descriptor
    # RegistrationDescriptor
    # ExtensionDescriptor

    return

  getDetails: (detailLevel) ->
    "audioSpecificConfig=0x#{@decoderConfigDescriptor.decoderSpecificInfo.specificInfo.toString 'hex'} maxBitrate=#{@decoderConfigDescriptor.maxBitrate} avgBitrate=#{@decoderConfigDescriptor.avgBitrate}"

  getTree: ->
    obj = super
    obj.audioSpecificConfig = [@decoderConfigDescriptor.decoderSpecificInfo.specificInfo...]
    obj.maxBitrate = @decoderConfigDescriptor.maxBitrate
    obj.avgBitrate = @decoderConfigDescriptor.avgBitrate
    return obj

# mp4a
# Defined in ISO 14496-14
class MP4AudioSampleEntry extends AudioSampleEntry
  read: (buf) ->
    super buf
    bits = new Bits @remaining_buf
    @children = [
      Box.parse bits, this, ESDBox
    ]
    return

# free: can be ignored
# Defined in ISO 14496-12
class FreeSpaceBox extends Box

# ctts: offset between decoding time and composition time
class CompositionOffsetBox extends Box
  read: (buf) ->
    bits = new Bits buf
    @readFullBoxHeader bits

    @entryCount = bits.read_uint32()
    @entries = []
    for i in [0...@entryCount]
      sampleCount = bits.read_uint32()
      sampleOffset = bits.read_uint32()
      @entries.push
        sampleCount: sampleCount
        sampleOffset: sampleOffset
    return

  # sampleNumber is indexed from 1
  getCompositionTimeOffset: (sampleNumber) ->
    for entry in @entries
      if sampleNumber <= entry.sampleCount
        return entry.sampleOffset
      sampleNumber -= entry.sampleCount
    throw new Error "mp4: ctts: composition time for sample number #{sampleNumber} not found"

# '\xa9too' (actually '\xa9' expands to [0xc2, 0xa9])
# (copyright sign) + 'too'
class CTOOBox extends GenericDataBox


api =
  MP4File: MP4File

module.exports = api
