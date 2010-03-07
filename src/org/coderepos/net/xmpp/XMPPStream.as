package org.coderepos.net.xmpp
{
    import flash.events.EventDispatcher;
    import flash.events.Event;
    import flash.events.IOErrorEvent;
    import flash.events.SecurityErrorEvent;

    import org.coderepos.sasl.SASLMechanismFactory;
    import org.coderepos.sasl.SASLMechanismDefaultFactory;
    import org.coderepos.sasl.mechanisms.ISASLMechanism;

    import org.coderepos.xml.sax.XMLElementEventHandler;

    import org.coderepos.net.xmpp.handler.IXMPPStreamHandler;
    import org.coderepos.net.xmpp.handler.InitialHandler;
    import org.coderepos.net.xmpp.handler.TLSHandler;
    import org.coderepos.net.xmpp.handler.SASLHandler;
    import org.coderepos.net.xmpp.handler.ResourceBindingHandler;
    import org.coderepos.net.xmpp.handler.SessionEstablishmentHandler;
    import org.coderepos.net.xmpp.handler.InitialRosterHandler;
    import org.coderepos.net.xmpp.handler.CompletedHandler;

    import org.coderepos.net.xmpp.exceptions.XMPPProtocolError;
    import org.coderepos.net.xmpp.events.XMPPMessageEvent;
    import org.coderepos.net.xmpp.events.XMPPSubscriptionEvent;
    import org.coderepos.net.xmpp.events.XMPPPresenceEvent;
    import org.coderepos.net.xmpp.events.XMPPErrorEvent;
    import org.coderepos.net.xmpp.util.IDGenerator;
    import org.coderepos.net.xmpp.roster.RosterItem;

    public class XMPPStream extends EventDispatcher
    {
        private var _config:XMPPConfig;
        private var _connection:XMPPConnection;
        private var _handler:IXMPPStreamHandler;
        private var _attributes:Object;
        private var _features:XMPPServerFeatures;
        private var _saslFactory:SASLMechanismFactory;
        private var _jid:JID;
        private var _boundJID:JID;
        private var _idGenerator:IDGenerator;
        private var _roster:Object;
        private var _isReady:Boolean;

        public function XMPPStream(config:XMPPConfig)
        {
            _config      = config;
            _attributes  = {};
            _roster      = {};
            _isReady     = false;
            _features    = new XMPPServerFeatures();
            _jid         = new JID(_config.username);
            _idGenerator = new IDGenerator("req:", 5);
            _saslFactory = new SASLMechanismDefaultFactory(
                _jid.node, _config.password, null, "xmpp", _jid.domain);
            // XXX: JID validation ?
        }

        [InternalAPI]
        public function get applicationName():String
        {
            return _config.applicationName;
        }

        [InternalAPI]
        public function get applicationVersion():String
        {
            return _config.applicationVersion;
        }

        [InternalAPI]
        public function get applicationNode():String
        {
            return _config.applicationNode;
        }

        [InternalAPI]
        public function get applicationType():String
        {
            return _config.applicationType;
        }

        [InternalAPI]
        public function get applicationCategory():String
        {
            return _config.applicationCategory;
        }

        [InternalAPI]
        public function genNextID():String
        {
            return _idGenerator.generate();
        }

        [InternalAPI]
        public function get domain():String
        {
            return _jid.domain;
        }

        [InternalAPI]
        public function set features(features:XMPPServerFeatures):void
        {
            _features = features;
        }

        [ExternalAPI]
        public function getAttribute(key:String):String
        {
            return (key in _attributes) ? _attributes[key] : null;
        }

        [ExternalAPI]
        public function setAttribute(key:String, value:String):void
        {
            _attributes[key] = value;
        }

        [ExternalAPI]
        public function get connected():Boolean
        {
            return (_connection != null && _connection.connected);
        }

        [ExternalAPI]
        public function start():void
        {
            if (connected)
                throw new Error("already connected.");

            _connection = new XMPPConnection(_config);
            _connection.addEventListener(Event.CONNECT, connectHandler);
            _connection.addEventListener(Event.CLOSE, closeHandler);
            _connection.addEventListener(IOErrorEvent.IO_ERROR, ioErrorHandler);
            _connection.addEventListener(SecurityErrorEvent.SECURITY_ERROR, securityErrorHandler);
            _connection.addEventListener(XMPPErrorEvent.PROTOCOL_ERROR, protocolErrorHandler);
            _connection.connect();
        }

        [ExternalAPI]
        public function send(s:String):void
        {
            if (connected)
                _connection.send(s);
        }

        [InternalAPI]
        public function setXMLEventHandler(handler:XMLElementEventHandler):void
        {
            if (connected)
                _connection.setXMLEventHandler(handler);
        }

        [InternalAPI]
        public function dispose():void
        {
            _handler = null;
            _isReady = false;
        }

        [InternalAPI]
        public function clearBuffer():void
        {
            trace("[CLEAR BUFFER]");
            if (connected)
                _connection.clearBuffer();
        }

        [ExternalAPI]
        public function disconnect():void
        {
            if (connected)
                _connection.disconnect();
            dispose();
        }

        [InternalAPI]
        public function changeState(handler:IXMPPStreamHandler):void
        {
            _handler = handler;
            _handler.run();
        }

        [InternalAPI]
        public function initiated():void
        {
            if (_features.supportTLS) {
                changeState(new TLSHandler(this));
            } else {
                var mech:ISASLMechanism = findProperSASLMechanism();
                if (mech != null) {
                    changeState(new SASLHandler(this, mech));
                } else if (_features.supportNonSASLAuth) {
                    //changeState(new NonSASLAuthHandler(this, _config.username,
                    //_config.password));
                } else {
                    // XXX: Accept anonymous ?
                    throw new XMPPProtocolError(
                        "Server doesn't support neither SASL or IQ-Auth");
                }
            }
        }

        [InternalAPI]
        public function switchToTLS():void
        {
            if (connected)
                _connection.startTLS();
        }

        [InternalAPI]
        public function tlsNegotiated():void
        {
            var mech:ISASLMechanism = findProperSASLMechanism();
            if (mech != null) {
                changeState(new SASLHandler(this, mech));
            } else if (_features.supportNonSASLAuth) {
                //changeState(new NonSASLAuthHandler(this, _config.username,
                //_config.password));
            } else {
                // XXX: Accept anonymous ?
                throw new XMPPProtocolError(
                    "Server doesn't support neither SASL or IQ-Auth");
            }
        }

        [InternalAPI]
        public function authenticated():void
        {
            if (_features.supportResourceBinding) {
                changeState(new ResourceBindingHandler(this, _config.resource));
            } else {
                // without Binding
                throw new XMPPProtocolError(
                    "Server doesn't support resource-binding");
            }
        }

        [InternalAPI]
        public function bindJID(jid:JID):void
        {
            _boundJID = jid;
            if (_features.supportSession) {
                changeState(new SessionEstablishmentHandler(this));
            } else {
                changeState(new InitialRosterHandler(this));
            }
        }

        [InternalAPI]
        public function establishedSession():void
        {
            changeState(new InitialRosterHandler(this));
        }

        [ExternalAPI]
        public function get roster():Object
        {
            // should make iterator to encupsulate?
            return _roster;
        }

        [InternalAPI]
        public function initiatedRoster():void
        {
            updatedRoster();
            changeState(new CompletedHandler(this));
            _isReady = true;
        }

        [InternalAPI]
        public function updatedRoster():void
        {
            //dispatchEvent(new XMPPRosterEvent.UPDATED, _roster);
        }

        private function findProperSASLMechanism():ISASLMechanism
        {
            if (!_features.supportSASL)
                return null;
            var mech:ISASLMechanism = null;
            for each(var mechName:String in _features.saslMechs) {
                trace(mechName);
                mech = _saslFactory.getMechanism(mechName);
                if (mech != null)
                    break;
            }
            return mech;
        }

        [InternalAPI]
        public function setRosterItem(rosterItem:RosterItem):void
        {
            var jidString:String = rosterItem.jid.toBareJIDString();
            if (jidString in _roster) {
                _roster[jidString].update(rosterItem);
            } else {
                _roster[jidString] = rosterItem;
            }
        }

        [InternalAPI]
        public function changedChatState(from:JID, state:String):void
        {
            var jidString:String = from.toBareJIDString();
            var resource:String  = from.resource;
            /*
            if (jidString in _roster) {
                if (_roster[jidString].hasResource(resource)) {
                    _roster[jidString].getResource(resource).changeState(state);
                }
            }
            */

            // dispatchEvent(
            //    new XMPPChatStateEvent(XMPPChatState.STATE_CHANGED, from, state));
        }

        [InternalAPI]
        public function receivedMessage(message:XMPPMessage):void
        {
            dispatchEvent(new XMPPMessageEvent(XMPPMessageEvent.RECEIVED, message));
        }

        [ExternalAPI]
        public function changePresence(isAvailable:Boolean, show:String,
            status:String, priority:int=0):void
        {
            if (!_isReady)
                throw new Error("not ready");

            // check priority >= -127 && priority <= 128
            if (priority <= -128 && priority > 128)
                throw new ArgumentError("priority must be in between -127 and 128");

            var presenceTag:String = '<presence';
            if (!isAvailable)
                presenceTag += ' type="' + PresenceType.UNAVAILABLE + '"'

            var hasNotChild:Boolean =
                (show == null && status == null && priority < 0);
            if (hasNotChild) {
                presenceTag += '/>';
            } else {
                presenceTag += '>';
                if (show != null)
                    presenceTag += '<show>' + show + '</show>';
                if (status != null)
                    presenceTag += '<status>' + status + '</status>';
                if (priority != 0)
                    presenceTag += '<priority>' + String(priority) + '</priority>';

                // TODO: vcard avatar
                presenceTag += '<x xmlns="' + XMPPNamespace.VCARD_UPDATE + '">';
                presenceTag += '<photo/>'
                presenceTag += '</x>';

                presenceTag += '</presence>';
            }
            send(presenceTag);
        }

        [InternalAPI]
        public function receivedPresence(presence:XMPPPresence):void
        {
            // XXX: should update roster-resource here ?

            dispatchEvent(new XMPPPresenceEvent(
                XMPPPresenceEvent.RECEIVED, presence));
        }

        [InternalAPI]
        public function receivedSubscriptionRequest(sender:JID):void
        {
            dispatchEvent(new XMPPSubscriptionEvent(
                XMPPSubscriptionEvent.RECEIVED, sender));
        }

        [ExternalAPI]
        public function acceptSubscriptionRequest(contact:JID):void
        {
            if (_isReady)
                send(
                    '<presence to="' + contact.toBareJIDString()
                    + '" type="' + PresenceType.SUBSCRIBED + '"/>'
                );
        }

        [ExternalAPI]
        public function denySubscriptionRequest(contact:JID):void
        {
            if (_isReady)
                send(
                    '<presence to="' + contact.toBareJIDString()
                    + '" type="' + PresenceType.UNSUBSCRIBED + '"/>'
                );
        }

        [InternalAPI]
        public function receivedSubscriptionResponse(sender:JID, type:String):void
        {
            // dispatch only?
            // no need to edit some roster data, because roster-push comes.
        }

        [ExternalAPI]
        public function subscribe(contact:JID):void
        {
            if (_isReady)
                send('<presence to="' + contact.toBareJIDString()
                    + '" type="' + PresenceType.SUBSCRIBE + '" />');
        }

        [ExternalAPI]
        public function unsubscribe(contact:JID):void
        {
            if (_isReady && contact.toBareJIDString() in _roster)
                send('<presence to="' + contact.toBareJIDString()
                    + '" type="' + PresenceType.UNSUBSCRIBE + '" />');
        }

        [ExternalAPI]
        public function getLastSeconds(contact:JID):void
        {
            if (_isReady) // and check if this contacts support jappber:iq:last
                send(
                      '<iq to="'     + contact.toString()
                        + '" id="'   + genNextID()
                        + '" type="' + IQType.GET + '">'
                    + '<query xmlns="' + XMPPNamespace.IQ_LAST + '" />'
                    + '</iq>'
                );
        }

        [InternalAPI]
        public function gotLastSeconds(contact:JID, seconds:uint):void
        {
            // TODO: search person from roster and update 'seconds'
        }

        [ExternalAPI]
        public function getVersion(contact:JID):void
        {
            if (_isReady) // and check if this contacts support jappber:iq:version
                send(
                    '<iq to="'       + contact.toString()
                        + '" id="'   + genNextID()
                        + '" type="' + IQType.GET + '">'
                    + '<query xmlns="' + XMPPNamespace.IQ_VERSION + '" />'
                    + '</iq>'
                );
        }

        [InternalAPI]
        public function gotVersion(contact:JID, name:String,
            version:String, os:String):void
        {
            // TODO: search person from roster and update 'version'
        }

        /* MUC
        public function joinRoom(roomID:JID):void
        {
            send('<presence to="' + roomID.toBareJIDString() + '">');
        }

        public function sendMessageWithinRoom(roomID:JID, message:String):void
        {
            send(
                  '<message to="' + roomID.toBareJIDString()
                    + '" type="' + MessageType.GROUPCHAT + '">'
                + '<body>' + message + '</body>'
                + '</message>'
                );
        }

        public function partFromRoom(roomUserID:JID):void
        {
            send('<presence type="' + PresenceType.UNAVAILABLE
                + '" to="' + roomUserID.toString() + '"/>');
        }
        */

        private function connectHandler(e:Event):void
        {
            dispatchEvent(e);
            changeState(new InitialHandler(this));
        }

        private function closeHandler(e:Event):void
        {
            dispose();
            dispatchEvent(e);
        }

        private function ioErrorHandler(e:IOErrorEvent):void
        {
            dispose();
            dispatchEvent(e);
        }

        private function securityErrorHandler(e:SecurityErrorEvent):void
        {
            dispose();
            dispatchEvent(e);
        }

        private function protocolErrorHandler(e:XMPPErrorEvent):void
        {
            dispose();
            dispatchEvent(e);
        }
    }
}

