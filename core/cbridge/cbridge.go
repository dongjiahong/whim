package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"unsafe"

	"whim/core/mobile"
)

func main() {}

func okJSON(data string) *C.char {
	b, _ := json.Marshal(map[string]any{
		"ok":   true,
		"data": json.RawMessage(data),
	})
	return C.CString(string(b))
}

func okString(val string) *C.char {
	b, _ := json.Marshal(map[string]any{
		"ok":   true,
		"data": val,
	})
	return C.CString(string(b))
}

func okInt(val int) *C.char {
	b, _ := json.Marshal(map[string]any{
		"ok":   true,
		"data": val,
	})
	return C.CString(string(b))
}

func errJSON(err error) *C.char {
	b, _ := json.Marshal(map[string]any{
		"ok":    false,
		"error": err.Error(),
	})
	return C.CString(string(b))
}

//export WhimFreeString
func WhimFreeString(s *C.char) {
	if s != nil {
		C.free(unsafe.Pointer(s))
	}
}

//export WhimInit
func WhimInit(dataDir, displayName *C.char) *C.char {
	if err := mobile.Init(C.GoString(dataDir), C.GoString(displayName)); err != nil {
		return errJSON(err)
	}
	return okString("initialized")
}

//export WhimClose
func WhimClose() *C.char {
	if err := mobile.Close(); err != nil {
		return errJSON(err)
	}
	return okString("closed")
}

//export WhimSaveBlob
func WhimSaveBlob(ptr unsafe.Pointer, length C.int, mime *C.char) *C.char {
	data := C.GoBytes(ptr, length)
	res, err := mobile.SaveBlob(data, C.GoString(mime))
	if err != nil {
		return errJSON(err)
	}
	return okJSON(res)
}

//export WhimCreateNote
func WhimCreateNote(content, attachmentsJSON *C.char) *C.char {
	res, err := mobile.CreateNote(C.GoString(content), C.GoString(attachmentsJSON))
	if err != nil {
		return errJSON(err)
	}
	return okJSON(res)
}

//export WhimUpdateNote
func WhimUpdateNote(patchJSON *C.char) *C.char {
	res, err := mobile.UpdateNote(C.GoString(patchJSON))
	if err != nil {
		return errJSON(err)
	}
	return okJSON(res)
}

//export WhimListNotes
func WhimListNotes(filterJSON *C.char) *C.char {
	res, err := mobile.ListNotes(C.GoString(filterJSON))
	if err != nil {
		return errJSON(err)
	}
	return okJSON(res)
}

//export WhimListTodayNotes
func WhimListTodayNotes() *C.char {
	res, err := mobile.ListTodayNotes()
	if err != nil {
		return errJSON(err)
	}
	return okJSON(res)
}

//export WhimCountTodayNotes
func WhimCountTodayNotes() *C.char {
	cnt, err := mobile.CountTodayNotes()
	if err != nil {
		return errJSON(err)
	}
	return okInt(cnt)
}

//export WhimListTagTree
func WhimListTagTree() *C.char {
	res, err := mobile.ListTagTree()
	if err != nil {
		return errJSON(err)
	}
	return okJSON(res)
}

//export WhimStartPeerServer
func WhimStartPeerServer(port C.int) *C.char {
	p, err := mobile.StartPeerServer(int(port))
	if err != nil {
		return errJSON(err)
	}
	return okInt(p)
}

//export WhimStopPeerServer
func WhimStopPeerServer() *C.char {
	if err := mobile.StopPeerServer(); err != nil {
		return errJSON(err)
	}
	return okString("stopped")
}

//export WhimSyncOnce
func WhimSyncOnce(timeoutSec C.int) *C.char {
	res, err := mobile.SyncOnce(int(timeoutSec))
	if err != nil {
		return errJSON(err)
	}
	return okJSON(res)
}

//export WhimGetPairCode
func WhimGetPairCode() *C.char {
	code, err := mobile.GetPairCode()
	if err != nil {
		return errJSON(err)
	}
	return okString(code)
}

//export WhimSetPairCode
func WhimSetPairCode(code *C.char) *C.char {
	updated, err := mobile.SetPairCode(C.GoString(code))
	if err != nil {
		return errJSON(err)
	}
	return okString(updated)
}

//export WhimRegeneratePairCode
func WhimRegeneratePairCode() *C.char {
	code, err := mobile.RegeneratePairCode()
	if err != nil {
		return errJSON(err)
	}
	return okString(code)
}

//export WhimSetManualPeers
func WhimSetManualPeers(addrsJSON *C.char) *C.char {
	if err := mobile.SetManualPeers(C.GoString(addrsJSON)); err != nil {
		return errJSON(err)
	}
	return okString("saved")
}

//export WhimDiscoverLAN
func WhimDiscoverLAN() *C.char {
	res, err := mobile.DiscoverLAN()
	if err != nil {
		return errJSON(err)
	}
	return okJSON(res)
}

//export WhimPairAndSync
func WhimPairAndSync(addr, remoteCode *C.char) *C.char {
	res, err := mobile.PairAndSync(C.GoString(addr), C.GoString(remoteCode))
	if err != nil {
		return errJSON(err)
	}
	return okJSON(res)
}

//export WhimListPairedPeers
func WhimListPairedPeers() *C.char {
	res, err := mobile.ListPairedPeers()
	if err != nil {
		return errJSON(err)
	}
	return okJSON(res)
}

//export WhimRemovePairedPeer
func WhimRemovePairedPeer(peerID *C.char) *C.char {
	if err := mobile.RemovePairedPeer(C.GoString(peerID)); err != nil {
		return errJSON(err)
	}
	return okString("removed")
}

//export WhimExportMarkdown
func WhimExportMarkdown(filterJSON, outDir *C.char) *C.char {
	res, err := mobile.ExportMarkdown(C.GoString(filterJSON), C.GoString(outDir))
	if err != nil {
		return errJSON(err)
	}
	return okJSON(res)
}
