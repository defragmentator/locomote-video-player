package com.axis.rtspclient {

  import flash.events.EventDispatcher;
  import flash.events.Event;
  import flash.utils.ByteArray;
  import flash.net.Socket;
  import mx.utils.ObjectUtil;

  import com.axis.rtspclient.FLVMux;
  import com.axis.rtspclient.RTP;
  import com.axis.rtspclient.SDP;
  import com.axis.http.url;
  import com.axis.http.request;
  import com.axis.http.auth;

  public class RTSPClient extends EventDispatcher {
    private static var userAgent:String = "Slush 0.1";

    private static var STATE_INITIAL:uint   = 1 << 0;
    private static var STATE_OPTIONS:uint   = 1 << 1;
    private static var STATE_DESCRIBE:uint  = 1 << 2;
    private static var STATE_SETUP:uint     = 1 << 3;
    private static var STATE_PLAY:uint      = 1 << 4;
    private static var STATE_PLAYING:uint   = 1 << 5;
    private static var STATE_PAUSE:uint     = 1 << 6;
    private static var STATE_PAUSED:uint    = 1 << 7;
    private static var STATE_TEARDOWN:uint  = 1 << 8;

    private var state:int = STATE_INITIAL;
    private var handle:IRTSPHandle;

    private var sdp:SDP = new SDP();
    private var flvmux:FLVMux;

    private var urlParsed:Object;
    private var cSeq:uint = 1;
    private var session:String;
    private var contentBase:String;
    private var interleaveChannelIndex:uint = 0;

    private var methods:Array = [];
    private var data:ByteArray = new ByteArray();
    private var rtpLength:int = -1;
    private var rtpChannel:int = -1;
    private var tracks:Array;

    private var authState:String = "none";
    private var authOpts:Object = {};
    private var digestNC:uint = 1;

    public function RTSPClient(handle:IRTSPHandle, urlParsed:Object) {
      this.handle = handle;
      this.urlParsed = urlParsed;
      handle.addEventListener('data', onData);
      state = STATE_INITIAL;
    }

    public function start():Boolean {
      if (state !== STATE_INITIAL) {
        trace('Cannot start unless in initial state.');
        return false;
      }

      if (0 === this.methods.length) {
        /* We don't know the options yet. Start with that. */
        sendOptionsReq();
      } else {
        /* Already queried the options (and perhaps got unauthorized on describe) */
        sendDescribeReq();
      }
      return true;
    }

    public function pause():Boolean
    {
      if (state !== STATE_PLAYING) {
        trace('Unable to pause a stream if not playing.');
        return false;
      }

      try {
        sendPauseReq();
      } catch (err:Error) {
        trace("Unable to pause: " + err.message);
        return false;
      }

      return true;
    }

    public function resume():Boolean
    {
      if (state !== STATE_PAUSED) {
        trace('Unable to resume a stream if not paused.');
        return false;
      }

      sendPlayReq();
      return true;
    }

    public function stop():Boolean
    {
      if (state < STATE_PLAY) {
        trace('Unable to stop if we never reached play.');
        return false;
      }
      sendTeardownReq();
      return true;
    }

    private function onData(event:Event):void
    {
      /* read one byte to determine destination */
      if (0 < data.bytesAvailable) {
        /* Determining byte have already been read. This is a continuation */
      } else {
        /* Read the determining byte */
        handle.readBytes(data, 0, 1);
      }

      switch(data[0]) {
        case 0x52:
          /* ascii 'R', start of RTSP */
          onRTSP();
          break;

        case 0x24:
          /* ascii '$', start of interleaved packet */
          onInterleavedData();
          break;

        default:
          trace('Unknown determining byte:', data[0]);
          break;
      }
    }

    private function requestReset():void
    {
      var copy:ByteArray = new ByteArray();
      data.readBytes(copy);
      data.clear();
      copy.readBytes(data);

      rtpLength  = -1;
      rtpChannel = -1;
    }

    private function readRequest(oBody:ByteArray):*
    {
      var parsed:* = request.readHeaders(handle, data);
      if (false === parsed) {
        return false;
      }

      if (401 === parsed.code) {
        /* Unauthorized, change authState and (possibly) try again */
        authOpts = parsed.headers['www-authenticate'];
        var newAuthState:String = auth.nextMethod(authState, authOpts);
        if (authState === newAuthState) {
          trace('GET: Exhausted all authentication methods.');
          trace('GET: Unable to authorize to ' + urlParsed.host);
          return false;
        }

        trace('RTSPClient: switching http-authorization from ' + authState + ' to ' + newAuthState);
        authState = newAuthState;
        state = STATE_INITIAL;
        data = new ByteArray();
        handle.reconnect();
        return false;
      }

      if (data.bytesAvailable < parsed.headers['content-length']) {
        return false;
      }

      /* RTSP commands contain no heavy body, so it's safe to read everything */
      data.readBytes(oBody, 0, parsed.headers['content-length']);
      requestReset();
      return parsed;
    }

    private function onRTSP():void {
      var parsed:*, body:ByteArray = new ByteArray();
      if (false === (parsed = readRequest(body))) {
        return;
      }

      if (200 !== parsed.code) {
        trace('RTSPClient: Invalid RTSP response - ', parsed.code, parsed.message);
        return;
      }

      switch (state) {
      case STATE_INITIAL:
        trace("RTSPClient: STATE_INITIAL");

      case STATE_OPTIONS:
        trace("RTSPClient: STATE_DESCRIBE");
        this.methods = parsed.headers.public.split(/[ ]*,[ ]*/);
        sendDescribeReq();

        break;
      case STATE_DESCRIBE:
        trace("RTSPClient: STATE_DESCRIBE");

        if (!sdp.parse(body)) {
          trace("RTSPClient:Failed to parse SDP file");
          return;
        }

        if (!parsed.headers['content-base']) {
          trace('RTSPClient: no content-base in describe reply');
          return;
        }

        contentBase = parsed.headers['content-base'];
        tracks = sdp.getMediaBlockList();
        trace('SDP contained ' + tracks.length + ' track(s). Calling SETUP for each.');

        if (0 === tracks.length) {
          trace('No tracks in SDP file.');
          return;
        }

        /* Fall through, it's time for setup */
      case STATE_SETUP:
        trace("RTSPClient: STATE_SETUP");

        if (parsed.headers['session']) {
          session = parsed.headers['session'];
        }

        if (0 !== tracks.length) {
          /* More tracks we must setup before playing */
          var block:Object = tracks.shift();
          sendSetupReq(block);
          return;
        }

        /* All tracks setup and ready to go! */
        sendPlayReq();
        break;

      case STATE_PLAY:
        trace("RTSPClient: STATE_PLAY");
        state = STATE_PLAYING;

        if (this.flvmux) {
          /* If the flvmux have been initialized don't do it again.
             this is probably a resume after pause */
          break;
        }

        this.flvmux = new FLVMux(this.sdp);
        var analu:ANALU = new ANALU();
        var aaac:AAAC = new AAAC(sdp);

        this.addEventListener("VIDEO_PACKET", analu.onRTPPacket);
        this.addEventListener("AUDIO_PACKET", aaac.onRTPPacket);
        analu.addEventListener(NALU.NEW_NALU, flvmux.onNALU);
        aaac.addEventListener(AACFrame.NEW_FRAME, flvmux.onAACFrame);
        break;

      case STATE_PLAYING:
        trace("RTSPClient: STATE_PLAYING");
        break;

      case STATE_PAUSE:
        trace("RTSPClient: STATE_PAUSE");
        state = STATE_PAUSED;
        break;

      case STATE_TEARDOWN:
        trace('RTSPClient: STATE_TEARDOWN');
        break;
      }
    }

    private function onInterleavedData():void
    {
      handle.readBytes(data, data.length);

      if (-1 == rtpLength && 0x24 === data[0]) {
        /* This is the beginning of a new RTP package */
        data.readByte();
        rtpChannel = data.readByte();
        rtpLength = data.readShort();
      }

      if (data.bytesAvailable < rtpLength) {
        /* The complete RTP package is not here yet, wait for more data */
        return;
      }

      var pkgData:ByteArray = new ByteArray();

      data.readBytes(pkgData, 0, rtpLength);

      if (rtpChannel === 0 || rtpChannel === 2) {
        /* We're discarding the RTCP counter parts for now */
        var rtppkt:RTP = new RTP(pkgData, sdp);
        dispatchEvent(rtppkt);
      }

      requestReset();

      if (0 < data.bytesAvailable) {
        onData(null);
      }
    }

    private function supportCommand(command:String):Boolean
    {
      return (-1 !== this.methods.indexOf(command));
    }

    private function sendOptionsReq():void {
      state = STATE_OPTIONS;
      var req:String =
        "OPTIONS * RTSP/1.0\r\n" +
        "CSeq: " + (++cSeq) + "\r\n" +
        "User-Agent: " + userAgent + "\r\n" +
        "\r\n";
      handle.writeUTFBytes(req);
    }

    private function sendDescribeReq():void {
      state = STATE_DESCRIBE;
      var u:String = 'rtsp://' + urlParsed.host + ":" + urlParsed.port + urlParsed.urlpath;
      var req:String =
        "DESCRIBE " + u + " RTSP/1.0\r\n" +
        "CSeq: " + (++cSeq) + "\r\n" +
        "User-Agent: " + userAgent + "\r\n" +
        "Accept: application/sdp\r\n" +
        auth.authorizationHeader("DESCRIBE", authState, authOpts, urlParsed, digestNC++) +
        "\r\n";
      handle.writeUTFBytes(req);
    }

    private function sendSetupReq(block:Object):void {
      state = STATE_SETUP;
      var interleavedChannels:String = interleaveChannelIndex++ + "-" + interleaveChannelIndex++;
      var p:String = url.isAbsolute(block.control) ? block.control : contentBase + block.control;

      trace('Setting up track: ' + p);
      var req:String =
        "SETUP " + p + " RTSP/1.0\r\n" +
        "CSeq: " + (++cSeq) + "\r\n" +
        "User-Agent: " + userAgent + "\r\n" +
        (session ? ("Session: " + session + "\r\n") : "") +
        "Transport: RTP/AVP/TCP;unicast;interleaved=" + interleavedChannels + "\r\n" +
        auth.authorizationHeader("SETUP", authState, authOpts, urlParsed, digestNC++) +
        "Date: " + new Date().toUTCString() + "\r\n" +
        "\r\n";
      handle.writeUTFBytes(req);
    }

    private function sendPlayReq():void {
      if (state === STATE_PAUSED) {
        /* NetStream was closed when pausing. Play it again if that is the case. */
        Player.getNetStream().play(null);
      }

      state = STATE_PLAY;

      var req:String =
        "PLAY " + contentBase + " RTSP/1.0\r\n" +
        "CSeq: " + (++cSeq) + "\r\n" +
        "User-Agent: " + userAgent + "\r\n" +
        "Session: " + session + "\r\n" +
        auth.authorizationHeader("PLAY", authState, authOpts, urlParsed, digestNC++) +
        "\r\n";
      handle.writeUTFBytes(req);
    }

    private function sendPauseReq():void {
      if (-1 === this.supportCommand("PAUSE")) {
        throw new Error('Pause is not supported by server.');
      }

      state = STATE_PAUSE;

      /* NetStream must be closed here, otherwise it will think of this rtsp pause
         as a very bad connection and buffer a lot before playing again. Not
         excellent for live data. */
      Player.getNetStream().close();

      var req:String =
        "PAUSE " + contentBase + " RTSP/1.0\r\n" +
        "CSeq: " + (++cSeq) + "\r\n" +
        "User-Agent: " + userAgent + "\r\n" +
        "Session: " + session + "\r\n" +
        auth.authorizationHeader("PAUSE", authState, authOpts, urlParsed, digestNC++) +
        "\r\n";
      handle.writeUTFBytes(req);
    }

    private function sendTeardownReq():void {
      state = STATE_TEARDOWN;
      var req:String =
        "TEARDOWN " + contentBase + " RTSP/1.0\r\n" +
        "CSeq: " + (++cSeq) + "\r\n" +
        "User-Agent: " + userAgent + "\r\n" +
        "Session: " + session + "\r\n" +
        auth.authorizationHeader("TEARDOWN", authState, authOpts, urlParsed, digestNC++) +
        "\r\n";
      handle.writeUTFBytes(req);
    }
  }
}
