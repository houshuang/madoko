/*---------------------------------------------------------------------------
  Copyright 2013 Microsoft Corporation.
 
  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the file "license.txt" at the root of this distribution.
---------------------------------------------------------------------------*/

if (typeof define !== 'function') { var define = require('amdefine')(module) }
define([],function() {

  function delayed(action,delay) {
    if (!delay && typeof setImmediate !== "undefined") {
      setImmediate( function(){ action(); } );  // on NodeJS
    }
    else { 
      setTimeout( function(){ action(); }, delay || 0 );
    }
  }

  function promiseWhen() {
    var ps = (arguments.length > 1 ? Array.prototype.slice.call(arguments) : (arguments[0] ? arguments[0] : []));
    var total = ps ? ps.length : 0;
    var count = 0;
    var result = [];
    var error = null;
    var continuation = new Promise();

    function setup(i) {
      result[i] = undefined;
      ps[i].then( function(res) {
        result[i] = res; 
        done();
      }, function(err) {
        error = err; 
        done();
      });    
    }
    
    function done() {
      count++;
      if (count<total) {
        if (total > 0) continuation.progress( count/total );
      }
      else if (error) {
        continuation.reject(error);
      }
      else {
        continuation.resolve(result);
      }
    }
    
    if (total <= 0) {
      delayed( function() { continuation.resolve(result); } );
    }
    else {      
      for(var i = 0; i < total; i++) {
        setup(i);
      }
    }

    return continuation;
  }

  var Promise = (function() {
    var Event = { Success: "resolve", Progress: "progress", Error: "reject" };

    function Promise( asyncAction ) {
      var self = this;
      self.listeners = [];
      self.completed = false;
      if (asyncAction && asyncAction.then) {
        // a promise itself, hook up to it.. this is used to interoperate with other libraries' promises
        asyncAction.then( 
          function() { self.resolve.apply(self,arguments); },
          function() { self.reject.apply(self,arguments); },
          function() { self.progress.apply(self,arguments); }
        );
      }
      else if (typeof asyncAction === "function") {
        // asynAction is a function that takes a continuation as its last argument 
        asyncAction( function(err) {
          if (err) {
            self.reject.apply(self,arguments);
          }
          else {
            var args = Array.prototype.slice.call(arguments,1);
            self.resolve.apply(self,args);
          }
        });
      }
    }

    Promise.when = function(promises) { 
      return promiseWhen(promises);
    }

    Promise.guarded = function(pred,action,after) { 
      if (pred) {
        return action().then( function() { return after(); } );
      }
      else {
        return after();
      }
    }


    Promise.rejected = function(err) {
      var promise = new Promise();
      delayed( function() { promise.reject(err); });
      return promise;
    }

    Promise.resolved = function() {
      var args = Array.prototype.slice.call(arguments);
      var promise = new Promise();
      delayed( function() { promise.resolve.apply(promise,args); });
      return promise;
    }

    Promise.do = function(action) {
      return Promise.resolved().then( function() { return action(); } );
    }

    Promise.maybe = function(p,action) {
      if (p && p.then) {
        return p.then(action);
      }
      else {
        return action(p);
      }
    }

    Promise.wrap = function(p) {
      return (p && p.then ? p : Promise.resolved(p));
    }

    Promise.prototype.always = function( action ) {
      var self = this;
      self.then( function(){ action(); }, function(){ action(); });
      return self; // ignores result of 'then'
    }

    Promise.prototype.then = function( onSuccess, onError, onProgress ) {
      var self = this;
      var listener;

      if (onSuccess && onSuccess.then) {
        // propagate to a promise
        listener = {
          continuation: (onSuccess instanceof Promise ? onSuccess : new Promise(onSuccess))
          // no handlers: will propagate immediately to the onSucces promise
        }
      } 
      else {
        // set up handlers
        listener = { 
          continuation: new Promise(),
          resolve: onSuccess,
          reject: onError,
          progress: onProgress
        };
      }
      self.listeners.push(listener);
      return listener.continuation;
    }

    Promise.prototype._onEvent = function(event,args) {
      var self = this;
      if (self.completed) return;
      self.completed = (event !== Event.Progress);

      self.listeners.forEach( function(listener) {
        var callback = listener[event];
        var continuation = listener.continuation;
        if (callback) {
          try {
            // invoke the callback
            var res = callback.apply(listener, args);
            if (self.completed) {     // if not progress
              if (res && res.then) {  // if the callback returned a promise, hook up to it..
                res.then( 
                  function() { continuation.resolve.apply(continuation, arguments); },
                  function() { continuation.reject.apply(continuation, arguments); },
                  function() { continuation.progress.apply(continuation, arguments); }
                );
              }
              else if (typeof res !== "undefined") {
                // if a regular value is returned, immediately invoke the success handler
                continuation.resolve(res);
              }
              else {
                // otherwise, invoke the continuation without any arguments
                continuation.resolve();
              }
            }
          }
          catch(exn) {
            // if an exception is raised in the callback, propagate the error (if not progress)
            if (self.completed) {
              continuation.reject(exn);
            }  
          }
        }
        else if (self.completed) {  // if not progress && no callback
          // just propagate the event to our listeners
          continuation[event].apply(continuation, args);
        }          
      });
    }

    Promise.prototype.resolve = function() {
      var self = this;
      self._onEvent(Event.Success,arguments);
    }

    Promise.prototype.progress = function() {
      var self = this;
      self._onEvent(Event.Progress,arguments);
    }

    Promise.prototype.reject = function() {
      var self = this;
      self._onEvent(Event.Error,arguments);
    }

    return Promise;
  })();

  return Promise;
});