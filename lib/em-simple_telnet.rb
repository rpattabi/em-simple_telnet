require "fiber"
require 'timeout' # for Timeout::Error
require "socket" # for SocketError
require "eventmachine"

##
# This defines EventMachine::defers_finished? which is used by StopWhenEMDone
# to stop EventMachine safely when everything is done. The method returns
# +true+ if the @threadqueue and @resultqueue are undefined/nil/empty *and*
# none of the threads in the threadpool isn't working anymore.
#
# To do this, the method ::spawn_threadpool is redefined to start threads that
# provide a thread-local variable :working (like
# <tt>thread_obj[:working]</tt>). This variable tells whether the thread is
# still working on a deferred action or not.
#
module EventMachine # :nodoc:
  def self.defers_finished?
    (not defined? @threadqueue or (tq=@threadqueue).nil? or tq.empty? ) and
    (not defined? @resultqueue or (rq=@resultqueue).nil? or rq.empty? ) and
    (not defined? @threadpool  or (tp=@threadpool).nil? or tp.none? {|t|t[:working]})
  end

  def self.spawn_threadpool
    until @threadpool.size == @threadpool_size.to_i
      thread = Thread.new do
        Thread.current.abort_on_exception = true
        while true
          Thread.current[:working] = false
          op, cback = *@threadqueue.pop
          Thread.current[:working] = true
          result = op.call
          @resultqueue << [result, cback]
          EventMachine.signal_loopbreak
        end
      end
      @threadpool << thread
    end
  end
end

##
# Provides the facility to connect to telnet servers using EventMachine. The
# asynchronity is hidden so you can use this library just like Net::Telnet in
# a seemingly synchronous manner. See README for an example.
#
#   EventMachine.run do
#
#     opts = {
#       host: "localhost",
#       username: "user",
#       password: "secret",
#     }
#
#     EM::P::SimpleTelnet.new(opts) do |host|
#       # already logged in
#       puts host.cmd("ls -la")
#     end
#   end
#
# Because of being event-driven, it performs quite well and can handle a lot
# of connections concurrently.
#
class EventMachine::Protocols::SimpleTelnet < EventMachine::Connection

  # :stopdoc:
  IAC   = 255.chr # "\377" # "\xff" # interpret as command
  DONT  = 254.chr # "\376" # "\xfe" # you are not to use option
  DO    = 253.chr # "\375" # "\xfd" # please, you use option
  WONT  = 252.chr # "\374" # "\xfc" # I won't use option
  WILL  = 251.chr # "\373" # "\xfb" # I will use option
  SB    = 250.chr # "\372" # "\xfa" # interpret as subnegotiation
  GA    = 249.chr # "\371" # "\xf9" # you may reverse the line
  EL    = 248.chr # "\370" # "\xf8" # erase the current line
  EC    = 247.chr # "\367" # "\xf7" # erase the current character
  AYT   = 246.chr # "\366" # "\xf6" # are you there
  AO    = 245.chr # "\365" # "\xf5" # abort output--but let prog finish
  IP    = 244.chr # "\364" # "\xf4" # interrupt process--permanently
  BREAK = 243.chr # "\363" # "\xf3" # break
  DM    = 242.chr # "\362" # "\xf2" # data mark--for connect. cleaning
  NOP   = 241.chr # "\361" # "\xf1" # nop
  SE    = 240.chr # "\360" # "\xf0" # end sub negotiation
  EOR   = 239.chr # "\357" # "\xef" # end of record (transparent mode)
  ABORT = 238.chr # "\356" # "\xee" # Abort process
  SUSP  = 237.chr # "\355" # "\xed" # Suspend process
  EOF   = 236.chr # "\354" # "\xec" # End of file
  SYNCH = 242.chr # "\362" # "\xf2" # for telfunc calls

  OPT_BINARY         =   0.chr # "\000" # "\x00" # Binary Transmission
  OPT_ECHO           =   1.chr # "\001" # "\x01" # Echo
  OPT_RCP            =   2.chr # "\002" # "\x02" # Reconnection
  OPT_SGA            =   3.chr # "\003" # "\x03" # Suppress Go Ahead
  OPT_NAMS           =   4.chr # "\004" # "\x04" # Approx Message Size Negotiation
  OPT_STATUS         =   5.chr # "\005" # "\x05" # Status
  OPT_TM             =   6.chr # "\006" # "\x06" # Timing Mark
  OPT_RCTE           =   7.chr # "\a"   # "\x07" # Remote Controlled Trans and Echo
  OPT_NAOL           =   8.chr # "\010" # "\x08" # Output Line Width
  OPT_NAOP           =   9.chr # "\t"   # "\x09" # Output Page Size
  OPT_NAOCRD         =  10.chr # "\n"   # "\x0a" # Output Carriage-Return Disposition
  OPT_NAOHTS         =  11.chr # "\v"   # "\x0b" # Output Horizontal Tab Stops
  OPT_NAOHTD         =  12.chr # "\f"   # "\x0c" # Output Horizontal Tab Disposition
  OPT_NAOFFD         =  13.chr # "\r"   # "\x0d" # Output Formfeed Disposition
  OPT_NAOVTS         =  14.chr # "\016" # "\x0e" # Output Vertical Tabstops
  OPT_NAOVTD         =  15.chr # "\017" # "\x0f" # Output Vertical Tab Disposition
  OPT_NAOLFD         =  16.chr # "\020" # "\x10" # Output Linefeed Disposition
  OPT_XASCII         =  17.chr # "\021" # "\x11" # Extended ASCII
  OPT_LOGOUT         =  18.chr # "\022" # "\x12" # Logout
  OPT_BM             =  19.chr # "\023" # "\x13" # Byte Macro
  OPT_DET            =  20.chr # "\024" # "\x14" # Data Entry Terminal
  OPT_SUPDUP         =  21.chr # "\025" # "\x15" # SUPDUP
  OPT_SUPDUPOUTPUT   =  22.chr # "\026" # "\x16" # SUPDUP Output
  OPT_SNDLOC         =  23.chr # "\027" # "\x17" # Send Location
  OPT_TTYPE          =  24.chr # "\030" # "\x18" # Terminal Type
  OPT_EOR            =  25.chr # "\031" # "\x19" # End of Record
  OPT_TUID           =  26.chr # "\032" # "\x1a" # TACACS User Identification
  OPT_OUTMRK         =  27.chr # "\e"   # "\x1b" # Output Marking
  OPT_TTYLOC         =  28.chr # "\034" # "\x1c" # Terminal Location Number
  OPT_3270REGIME     =  29.chr # "\035" # "\x1d" # Telnet 3270 Regime
  OPT_X3PAD          =  30.chr # "\036" # "\x1e" # X.3 PAD
  OPT_NAWS           =  31.chr # "\037" # "\x1f" # Negotiate About Window Size
  OPT_TSPEED         =  32.chr # " "    # "\x20" # Terminal Speed
  OPT_LFLOW          =  33.chr # "!"    # "\x21" # Remote Flow Control
  OPT_LINEMODE       =  34.chr # "\""   # "\x22" # Linemode
  OPT_XDISPLOC       =  35.chr # "#"    # "\x23" # X Display Location
  OPT_OLD_ENVIRON    =  36.chr # "$"    # "\x24" # Environment Option
  OPT_AUTHENTICATION =  37.chr # "%"    # "\x25" # Authentication Option
  OPT_ENCRYPT        =  38.chr # "&"    # "\x26" # Encryption Option
  OPT_NEW_ENVIRON    =  39.chr # "'"    # "\x27" # New Environment Option
  OPT_EXOPL          = 255.chr # "\377" # "\xff" # Extended-Options-List

  NULL = "\000"
  CR   = "\015"
  LF   = "\012"
  EOL  = CR + LF
  # :startdoc:

  # raised when establishing the TCP connection fails
  class ConnectionFailed < SocketError; end

  # raised when the login procedure fails
  class LoginFailed < Timeout::Error; end

  ##
  # Extens Timeout::Error by the attributes _hostname_ and _command_ so one
  # knows where the exception comes from and why.
  #
  class TimeoutError < Timeout::Error
    # hostname this timeout comes from
    attr_accessor :hostname

    # command that caused this timeout
    attr_accessor :command
  end

  # default options for new connections (used for merging)
  DefaultOptions = {
    host: "localhost",
    port: 23,
    prompt: %r{[$%#>] \z}n,
    connect_timeout: 3,
    timeout: 10,
    wait_time: 0,
    keep_alive: false,
    bin_mode: false,
    telnet_mode: true,
    output_log: nil,
    command_log: nil,
    login_prompt: %r{[Ll]ogin[: ]*\z}n,
    password_prompt: %r{[Pp]ass(?:word|phrase)[: ]*\z}n,
    username: nil,
    password: nil,

    # telnet protocol stuff
    SGA: false,
    BINARY: false,
  }.freeze

  # used to terminate the reactor when everything is done
  stop_ticks = 0
  StopWhenEMDone = lambda do
    stop_ticks += 1
    if stop_ticks >= 100
      stop_ticks = 0
      # stop when everything is done
      if self.connection_count.zero? and EventMachine.defers_finished?
        EventMachine.stop
      else
        EventMachine.next_tick(&StopWhenEMDone)
      end
    else
      EventMachine.next_tick(&StopWhenEMDone)
    end
  end

  # number of active connections
  @@_telnet_connection_count = 0

  class << self

    ##
    # Recognizes whether this call was issued by the user program or by
    # EventMachine. If the call was not issued by EventMachine, merges the
    # options provided with the DefaultOptions and creates a Fiber (not
    # started yet).  Inside the Fiber SimpleTelnet.connect would be called.
    #
    # If EventMachine's reactor is already running, just starts the Fiber.
    #
    # If it's not running yet, starts a new EventMachine reactor and starts the
    # Fiber. The EventMachine block is stopped using the StopWhenEMDone proc
    # (lambda).
    #
    # The (closed) connection is returned.
    #
    def new *args, &blk
      # call super if first argument is a connection signature of
      # EventMachine
      return super(*args, &blk) if args.first.is_a? Integer

      # This method was probably called with a Hash of connection options.

      # create new fiber to connect and execute block
      opts = args[0] || {}
      connection = nil
      fiber = Fiber.new do | callback |
        connection = connect(opts, &blk)
        callback.call if callback
      end

      if EventMachine.reactor_running?
        # Transfer control to the "inner" Fiber and stop the current one.
        # The block will be called after connect() returned to transfer control
        # back to the "outer" Fiber.
        outer_fiber = Fiber.current
        fiber.transfer ->{ outer_fiber.transfer }

      else
        # start EventMachine and stop it when connection is done
        EventMachine.run do
          fiber.resume
          EventMachine.next_tick(&StopWhenEMDone)
        end
      end
      return connection
    end

    ##
    # Merges DefaultOptions with _opts_. Establishes the connection to the
    # <tt>:host</tt> key using EventMachine.connect, logs in using #login and
    # passes the connection to the block provided. Closes the connection using
    # #close after the block terminates. The connection is then returned.
    #
    def connect opts
      opts = DefaultOptions.merge opts

      params = [
        # for EventMachine.connect
        opts[:host],
        opts[:port],
        self,

        # pass the *merged* options to SimpleTelnet#initialize
        opts
      ]

      # start establishing the connection
      connection = EventMachine.connect(*params)

      # set callback to be executed when connection establishing
      # fails/succeeds
      f = Fiber.current
      connection.connection_state_callback = lambda do |obj=nil|
        @connection_state_callback = nil
        f.resume obj
      end

      # block here and get result from establishing connection
      state = Fiber.yield

      # raise if exception (e.g. Telnet::ConnectionFailed)
      raise state if state.is_a? Exception

      # login
      connection.instance_eval { login }

      begin
        yield connection
      ensure
        # Use #close so a subclass can execute some kind of logout command
        # before the connection is closed.
        connection.close unless opts[:keep_alive]
      end

      return connection
    end

    ##
    # Returns the number of active connections
    # (<tt>@@_telnet_connection_count</tt>).
    #
    def connection_count
      @@_telnet_connection_count
    end
  end

  ##
  # Initializes the current instance. _opts_ is a Hash of options. The default
  # values are in the constant DefaultOptions. The following keys are
  # recognized:
  #
  # +:host+::
  #   the hostname or IP address of the host to connect to, as a String.
  #   Defaults to "localhost".
  #
  # +:port+::
  #   the port to connect to.  Defaults to 23.
  #
  # +:bin_mode+::
  #   if +false+ (the default), newline substitution is performed.  Outgoing LF
  #   is converted to CRLF, and incoming CRLF is converted to LF.  If +true+,
  #   this substitution is not performed.  This value can also be set with the
  #   #bin_mode= method.  The outgoing conversion only applies to the #puts
  #   and #print methods, not the #write method.  The precise nature of the
  #   newline conversion is also affected by the telnet options SGA and BIN.
  #
  # +:output_log+::
  #   the name of the file to write connection status messages and all
  #   received traffic to.  In the case of a proper Telnet session, this will
  #   include the client input as echoed by the host; otherwise, it only
  #   includes server responses.  Output is appended verbatim to this file.
  #   By default, no output log is kept.
  #
  # +:command_log+::
  #   the name of the file to write the commands executed in this Telnet
  #   session.  Commands are appended to this file.  By default, no command
  #   log is kept.
  #
  # +:prompt+::
  #   a regular expression matching the host's command-line prompt sequence.
  #   This is needed by the Telnet class to determine when the output from a
  #   command has finished and the host is ready to receive a new command.  By
  #   default, this regular expression is <tt>%r{[$%#>] \z}n</tt>.
  #
  # +:login_prompt+::
  #   a regular expression (or String, see #waitfor) used to wait for the
  #   login prompt.
  #
  # +:password_prompt+::
  #   a regular expression (or String, see #waitfor) used to wait for the
  #   password prompt.
  #
  # +:username+::
  #   the String that is sent to the telnet server after seeing the login
  #   prompt. Just leave this value as +nil+ which is the default value if you
  #   don't have to log in.
  #
  # +:password+::
  #   the String that is sent to the telnet server after seeing the password
  #   prompt. Just leave this value as +nil+ which is the default value if you
  #   don't have to print a password after printing the username.
  #
  # +:telnet_mode+::
  #   a boolean value, +true+ by default.  In telnet mode, traffic received
  #   from the host is parsed for special command sequences, and these
  #   sequences are escaped in outgoing traffic sent using #puts or #print
  #   (but not #write).  If you are connecting to a non-telnet service (such
  #   as SMTP or POP), this should be set to "false" to prevent undesired data
  #   corruption.  This value can also be set by the #telnetmode method.
  #
  # +:timeout+::
  #   the number of seconds (default: +10+) to wait before timing out while
  #   waiting for the prompt (in #waitfor).  Exceeding this timeout causes a
  #   TimeoutError to be raised.  You can disable the timeout by setting
  #   this value to +nil+.
  #
  # +:connect_timeout+::
  #   the number of seconds (default: +3+) to wait before timing out the
  #   initial attempt to connect. You can disable the timeout by setting this
  #   value to +nil+.
  #
  # +:wait_time+::
  #   the amount of time to wait after seeing what looks like a prompt (that
  #   is, received data that matches the Prompt option regular expression) to
  #   see if more data arrives.  If more data does arrive in this time, it
  #   assumes that what it saw was not really a prompt.  This is to try to
  #   avoid false matches, but it can also lead to missing real prompts (if,
  #   for instance, a background process writes to the terminal soon after the
  #   prompt is displayed).  By default, set to 0, meaning not to wait for
  #   more data.
  #
  # The options are actually merged in connect().
  #
  def initialize opts
    @telnet_options = opts
    @last_command = nil

    @logged_in = nil
    @connection_state = :connecting
    @connection_state_callback = nil
    @input_buffer = ""
    @input_rest = ""
    @wait_time_timer = nil
    @check_input_buffer_timer = nil

    setup_logging
  end

  # Last command that was executed in this telnet session
  attr_reader :last_command

  # Logger used to log output
  attr_reader :output_logger

  # Logger used to log commands
  attr_reader :command_logger

  # used telnet options Hash
  attr_reader :telnet_options

  # the callback executed after connection established or failed
  attr_accessor :connection_state_callback

  # last prompt matched
  attr_reader :last_prompt

  ##
  # Return current telnet mode option of this connection.
  #
  def telnet_mode?
    @telnet_options[:telnet_mode]
  end

  ##
  # Turn telnet command interpretation on or off for this connection.  It
  # should be on for true telnet sessions, off if used to connect to a
  # non-telnet service such as SMTP.
  #
  def telnet_mode=(bool)
    @telnet_options[:telnet_mode] = bool
  end

  ##
  # Return current bin mode option of this connection.
  #
  def bin_mode?
    @telnet_options[:bin_mode]
  end

  ##
  # Turn newline conversion on or off for this connection.
  #
  def bin_mode=(bool)
    @telnet_options[:bin_mode] = bool
  end

  ##
  # Set the activity timeout to _seconds_ for this connection.  To disable it,
  # set it to +0+ or +nil+.
  #
  def timeout= seconds
    @telnet_options[:timeout] = seconds
    set_comm_inactivity_timeout( seconds )
  end

  ##
  # If a block is given, sets the timeout to _seconds_ (see #timeout=),
  # executes the block and restores the previous timeout. The block value is
  # returned.  This is useful if you want to execute one or more commands with
  # a special timeout.
  #
  # If no block is given, the current timeout is returned.
  #
  # Example:
  #
  #  current_timeout = host.timeout
  #
  #   host.timeout 200 do
  #     host.cmd "command 1"
  #     host.cmd "command 2"
  #   end
  #
  def timeout seconds=nil
    if block_given?
      before = @telnet_options[:timeout]
      self.timeout = seconds
      begin
        yield
      ensure
        self.timeout = before
      end
    else
      if seconds
        warn "Warning: Use EM::P::SimpleTelnet#timeout= to set the timeout."
      end
      @telnet_options[:timeout]
    end
  end

  ##
  # When the login succeeded for this connection.
  #
  attr_reader :logged_in

  ##
  # Returns +true+ if the login already succeeded for this connection.
  # Returns +false+ otherwise.
  #
  def logged_in?
    @logged_in ? true : false
  end

  ##
  # Returns +true+ if the connection is closed.
  #
  def closed?
    @connection_state == :closed
  end

  ##
  # Called by EventMachine when data is received.
  #
  # The data is processed using #preprocess_telnet and appended to the
  # <tt>@input_buffer</tt>. The appended data is also logged using
  # #log_output. Then #check_input_buffer is called which checks the input
  # buffer for the prompt.
  #
  def receive_data data
    if @telnet_options[:telnet_mode]
      c = @input_rest + data
      se_pos = c.rindex(/#{IAC}#{SE}/no) || 0
      sb_pos = c.rindex(/#{IAC}#{SB}/no) || 0
      if se_pos < sb_pos
        buf = preprocess_telnet(c[0 ... sb_pos])
        @input_rest = c[sb_pos .. -1]

      elsif pt_pos = c.rindex(
        /#{IAC}[^#{IAC}#{AO}#{AYT}#{DM}#{IP}#{NOP}]?\z/no) ||
        c.rindex(/\r\z/no)

        buf = preprocess_telnet(c[0 ... pt_pos])
        @input_rest = c[pt_pos .. -1]

      else
        buf = preprocess_telnet(c)
        @input_rest.clear
      end
    else
      # Not Telnetmode.
      #
      # We cannot use #preprocess_telnet on this data, because that
      # method makes some Telnetmode-specific assumptions.
      buf = @input_rest + data
      @input_rest.clear
      unless @telnet_options[:bin_mode]
        if pt_pos = buf.rindex(/\r\z/no)
          buf = buf[0 ... pt_pos]
          @input_rest = buf[pt_pos .. -1]
        end
        buf.gsub!(/#{EOL}/no, "\n")
      end
    end

    # in case only telnet sequences were received
    return if buf.empty?

    # append output from server to input buffer and log it
    @input_buffer << buf
    log_output buf, true

    # cancel the timer for wait_time value because we received more data
    if @wait_time_timer
      @wait_time_timer.cancel
      @wait_time_timer = nil
    end

    # we only need to do something if there's a connection state callback
    return unless @connection_state_callback

    # we ensure there's no timer running to check the input buffer
    if @check_input_buffer_timer
      @check_input_buffer_timer.cancel
      @check_input_buffer_timer = nil
    end

    if @input_buffer.size >= 100_000
      ##
      # if the input buffer is really big
      #

      # We postpone checking the input buffer by one second because the regular
      # expression matches can get quite slow.
      #
      # So as long as data is received (continuously), the input buffer is not
      # checked. It's only checked one second after the whole output has been
      # received.
      @check_input_buffer_timer = EventMachine::Timer.new(1) do
        @check_input_buffer_timer = nil
        check_input_buffer
      end
    else
      ##
      # as long as the input buffer is small
      #

      # check the input buffer now
      check_input_buffer
    end
  end

  ##
  # Checks the input buffer (<tt>@input_buffer</tt>) for the prompt we're
  # waiting for. Calls the proc in <tt>@connection_state_callback</tt> if the
  # prompt has been found. Thus, call this method *only* if
  # <tt>@connection_state_callback</tt> is set!
  #
  # If <tt>@telnet_options[:wait_time]</tt> is set, this amount of seconds is
  # waited (call to <tt>@connection_state_callback</tt> is scheduled) after
  # seeing what looks like the prompt before firing the
  # <tt>@connection_state_callback</tt> is fired, so more data can come until
  # the real prompt is reached. This is useful for commands which will cause
  # multiple prompts to be sent.
  #
  def check_input_buffer
    if md = @input_buffer.match(@telnet_options[:prompt])
      blk = lambda do
        @last_prompt = md.to_s # remember last prompt
        output = md.pre_match + @last_prompt
        @input_buffer = md.post_match
        @connection_state_callback.call(output)
      end

      if s = @telnet_options[:wait_time] and s > 0
        # fire @connection_state_callback after s seconds
        @wait_time_timer = EventMachine::Timer.new(s, &blk)
      else
        # fire @connection_state_callback now
        blk.call
      end
    end
  end

  ##
  # Read data from the host until a certain sequence is matched.
  #
  # All data read will be returned in a single string.  Note that the received
  # data includes the matched sequence we were looking for.
  #
  # _prompt_ can be a Regexp or String. If it's not a Regexp, it's converted
  # to a Regexp (all special characters escaped) assuming it's a String.
  #
  # _opts_ can be a hash of options. The following options are used and thus
  # can be overridden:
  #
  # * +:timeout+
  # * +:wait_time+ (actually used by #check_input_buffer)
  #
  def waitfor prompt=nil, opts={}
    options_were = @telnet_options
    timeout_was = self.timeout if opts.key?(:timeout)
    opts[:prompt] = prompt if prompt
    @telnet_options = @telnet_options.merge opts

    # convert String prompt into a Regexp
    unless @telnet_options[:prompt].is_a? Regexp
      regex = Regexp.new(Regexp.quote(@telnet_options[:prompt]))
      @telnet_options[:prompt] = regex
    end

    # set custom inactivity timeout, if wanted
    self.timeout = @telnet_options[:timeout] if opts.key?(:timeout)

    # so #unbind knows we were waiting for a prompt (in case that inactivity
    # timeout fires)
    @connection_state = :waiting_for_prompt

    # for the block in @connection_state_callback
    f = Fiber.current

    # will be called by #receive_data to resume at "Fiber.yield" below
    @connection_state_callback = lambda do |output|
      @connection_state_callback = nil
      f.resume(output)
    end

    result = Fiber.yield

    raise result if result.is_a? Exception
    return result
  ensure
    @telnet_options = options_were
    self.timeout = timeout_was if opts.key?(:timeout)
    @connection_state = :connected
  end

  alias :write :send_data

  ##
  # Sends a string to the host.
  #
  # This does _not_ automatically append a newline to the string.  Embedded
  # newlines may be converted and telnet command sequences escaped depending
  # upon the values of #telnet_mode, #bin_mode, and telnet options set by the
  # host.
  #
  def print(string)
    string = string.gsub(/#{IAC}/no, IAC + IAC) if telnet_mode?

    unless bin_mode?
      string = if @telnet_options[:BINARY] and @telnet_options[:SGA]
        # IAC WILL SGA IAC DO BIN send EOL --> CR
        string.gsub(/\n/n, CR)

      elsif @telnet_options[:SGA]
        # IAC WILL SGA send EOL --> CR+NULL
        string.gsub(/\n/n, CR + NULL)

      else
        # NONE send EOL --> CR+LF
        string.gsub(/\n/n, EOL)
      end
    end

    send_data string
  end

  ##
  # Sends a string to the host.
  #
  # Same as #print, but appends a newline to the string unless there's
  # already one.
  #
  def puts(string)
    string += "\n" unless string.end_with? "\n"
    print string
  end

  ##
  # Sends a command to the host.
  #
  # More exactly, the following things are done:
  #
  # * stores the command in @last_command
  # * logs it using #log_command
  # * sends a string to the host (#print or #puts)
  # * reads in all received data (using #waitfor)
  # * returns the received data as String
  #
  # _opts_ can be a Hash of options. It is passed to #waitfor as the second
  # parameter. The element in _opts_ with the key <tt>:prompt</tt> is used as
  # the first parameter in the call to #waitfor. Example usage:
  # 
  #   host.cmd "delete user john", prompt: /Are you sure?/
  #   host.cmd "yes"
  #
  # Note that the received data includes the prompt and in most cases the
  # host's echo of our command.
  #
  # If _opts_ has the key <tt>:hide</tt> which evaluates to +true+, calls
  # #log_command with <tt>"<hidden command>"</tt> instead of the command
  # itself. This is useful for passwords, so they don't get logged to the
  # command log.
  #
  # If _opts_ has the key <tt>:raw_command</tt> which evaluates to +true+,
  # #print is used to send the command to the host instead of #puts.
  #
  def cmd command, opts={}
    command = command.to_s
    @last_command = command

    # log the command
    log_command(opts[:hide] ? "<hidden command>" : command)

    # send the command
    sendcmd = opts[:raw_command] ? :print : :puts
    self.__send__(sendcmd, command)

    # wait for the output
    waitfor(opts[:prompt], opts)
  end

  ##
  # Login to the host with a given username and password.
  #
  #   host.login username: "myuser", password: "mypass"
  #
  # This method looks for the login and password prompt (see implementation)
  # from the host to determine when to send the username and password.  If the
  # login sequence does not follow this pattern (for instance, you are
  # connecting to a service other than telnet), you will need to handle login
  # yourself.
  #
  # If the key <tt>:password</tt> is omitted (and not set on connection
  # level), the method will not look for a prompt.
  #
  # The method returns all data received during the login process from the
  # host, including the echoed username but not the password (which the host
  # should not echo anyway).
  #
  # Don't forget to set <tt>@logged_in</tt> after the login succeeds when you
  # redefine this method!
  #
  def login opts={}
    opts = @telnet_options.merge opts

    # don't log in if username is not set
    if opts[:username].nil?
      @logged_in = Time.now
      return
    end

    begin
      output = waitfor opts[:login_prompt]

      if opts[:password]
        # login with username and password
        output << cmd(opts[:username], prompt: opts[:password_prompt])
        output << cmd(opts[:password], hide: true)
      else
        # login with username only
        output << cmd(opts[:username])
      end
    rescue Timeout::Error
      e = LoginFailed.new("Timed out while expecting some kind of prompt.")
      e.set_backtrace $!.backtrace
      raise e
    end

    @logged_in = Time.now
    output
  end

  ##
  # Called by EventMachine when the connection is being established (not after
  # the connection is established! see #connection_completed).  This occurs
  # directly after the call to #initialize.
  #
  # Sets the +pending_connect_timeout+ to
  # <tt>@telnet_options[:connect_timeout]</tt> seconds. This is the duration
  # after which a TCP connection in the connecting state will fail (abort and
  # run #unbind). Increases <tt>@@_telnet_connection_count</tt> by one after
  # that.
  #
  # Sets also the +comm_inactivity_timeout+ to
  # <tt>@telnet_options[:timeout]</tt> seconds. This is the duration after
  # which a TCP connection is automatically closed if no data was sent or
  # received.
  #
  def post_init
    self.pending_connect_timeout = @telnet_options[:connect_timeout]
    self.comm_inactivity_timeout = @telnet_options[:timeout]
    @@_telnet_connection_count += 1
  end

  ##
  # Called by EventMachine after this connection is closed.
  #
  # Decreases <tt>@@_telnet_connection_count</tt> by one and calls #close_logs.
  #
  # After that and if <tt>@connection_state_callback</tt> is set, it takes a
  # look on <tt>@connection_state</tt>. If it was <tt>:connecting</tt>, calls
  # <tt>@connection_state_callback</tt> with a new instance of
  # ConnectionFailed. If it was <tt>:waiting_for_prompt</tt>, calls the
  # callback with a new instance of TimeoutError.
  #
  # Finally, the <tt>@connection_state</tt> is set to +closed+.
  #
  def unbind
    @@_telnet_connection_count -= 1
    close_logs

    if @connection_state_callback
      # if we were connecting or waiting for a prompt, return an exception to
      # #waitfor
      case @connection_state
      when :connecting
        @connection_state_callback.call(ConnectionFailed.new)
      when :waiting_for_prompt
        error = TimeoutError.new

        # set hostname and command
        if hostname = @telnet_options[:host]
          error.hostname = hostname
        end
        error.command = @last_command if @last_command

        @connection_state_callback.call(error)
      end
    end

    @connection_state = :closed
  end

  ##
  # Called by EventMachine after the connection is successfully established.
  #
  def connection_completed
    @connection_state = :connected
    @connection_state_callback.call if @connection_state_callback
  end

  ##
  # Tells EventMachine to close the connection after sending what's in the
  # output buffer. Redefine this method to execute some logout command like
  # +exit+ or +logout+ before the connection is closed. Don't forget: The
  # command will probably not return a prompt, so use #puts, which doesn't
  # wait for a prompt.
  #
  def close
    close_connection_after_writing
  end

  ##
  # Close output and command logs if they're set. IOError is rescued because
  # they could already be closed. #closed? can't be used, because the method
  # is not implemented by Logger, for example.
  #
  def close_logs
    begin @output_logger.close
    rescue IOError
    end if @telnet_options[:output_log]
    begin @command_logger.close
    rescue IOError
    end if @telnet_options[:command_log]
  end

  private

  ##
  # Sets up output and command logging.
  #
  def setup_logging
    require 'logger'
    if @telnet_options[:output_log]
      @output_logger = Logger.new @telnet_options[:output_log]
      log_output "\n# Starting telnet output log at #{Time.now}"
    end

    if @telnet_options[:command_log]
      @command_logger = Logger.new @telnet_options[:command_log]
    end
  end

  ##
  # Logs _output_ to output log. If _exact_ is +true+, it will use #print
  # instead of #puts.
  #
  def log_output output, exact=false
    return unless @telnet_options[:output_log]
    if exact
      @output_logger.print output
    else
      @output_logger.puts output
    end
  end

  ##
  # Logs _command_ to command log.
  #
  def log_command command
    return unless @telnet_options[:command_log]
    @command_logger.info command
  end

  ##
  # Preprocess received data from the host.
  #
  # Performs newline conversion and detects telnet command sequences.
  # Called automatically by #receive_data.
  #
  def preprocess_telnet string
    # combine CR+NULL into CR
    string = string.gsub(/#{CR}#{NULL}/no, CR) if telnet_mode?

    # combine EOL into "\n"
    string = string.gsub(/#{EOL}/no, "\n") unless bin_mode?

    # remove NULL
    string = string.gsub(/#{NULL}/no, '') unless bin_mode?

    string.gsub(/#{IAC}(
                 [#{IAC}#{AO}#{AYT}#{DM}#{IP}#{NOP}]|
                 [#{DO}#{DONT}#{WILL}#{WONT}]
                   [#{OPT_BINARY}-#{OPT_NEW_ENVIRON}#{OPT_EXOPL}]|
                 #{SB}[^#{IAC}]*#{IAC}#{SE}
               )/xno) do
      if    IAC == $1  # handle escaped IAC characters
        IAC
      elsif AYT == $1  # respond to "IAC AYT" (are you there)
        send_data("nobody here but us pigeons" + EOL)
        ''
      elsif DO[0] == $1[0]  # respond to "IAC DO x"
        if OPT_BINARY[0] == $1[1]
          @telnet_options[:BINARY] = true
          send_data(IAC + WILL + OPT_BINARY)
        else
          send_data(IAC + WONT + $1[1..1])
        end
        ''
      elsif DONT[0] == $1[0]  # respond to "IAC DON'T x" with "IAC WON'T x"
        send_data(IAC + WONT + $1[1..1])
        ''
      elsif WILL[0] == $1[0]  # respond to "IAC WILL x"
        if    OPT_BINARY[0] == $1[1]
          send_data(IAC + DO + OPT_BINARY)
        elsif OPT_ECHO[0] == $1[1]
          send_data(IAC + DO + OPT_ECHO)
        elsif OPT_SGA[0]  == $1[1]
          @telnet_options[:SGA] = true
          send_data(IAC + DO + OPT_SGA)
        else
          send_data(IAC + DONT + $1[1..1])
        end
        ''
      elsif WONT[0] == $1[0]  # respond to "IAC WON'T x"
        if    OPT_ECHO[0] == $1[1]
          send_data(IAC + DONT + OPT_ECHO)
        elsif OPT_SGA[0]  == $1[1]
          @telnet_options[:SGA] = false
          send_data(IAC + DONT + OPT_SGA)
        else
          send_data(IAC + DONT + $1[1..1])
        end
        ''
      else
        ''
      end
    end
  end
end
